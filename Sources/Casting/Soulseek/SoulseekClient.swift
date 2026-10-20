import Foundation
import Network

/// Events a `SoulseekClient` reports back to the UI layer (delivered on arbitrary threads).
enum SlskEvent: Sendable {
    case connected(username: String, greeting: String)
    case disconnected(reason: String?)
    case searchResults(token: UInt32, results: [SlskSearchResult])
    case downloadState(id: UUID, state: SlskDownloadState)
    case uploadStarted(id: UUID, username: String, virtualPath: String, size: UInt64)
    case uploadState(id: UUID, state: SlskUploadState)
    /// How often the server wants wishlist searches repeated.
    case wishlistInterval(seconds: Int)
    /// A private message from another user (already acknowledged to the server).
    case privateMessage(SlskPrivateMessage)
    /// A user went online, away or offline (watched users, or a status query).
    case userStatus(username: String, status: SlskUserStatus, privileged: Bool)
    case userStats(username: String, stats: SlskUserStats)
}

enum SlskUploadState: Equatable, Sendable {
    case waiting
    case transferring(sent: UInt64, total: UInt64)
    case finished
    case failed(String)
}

/// One file to fetch from a peer. The client writes into `partURL` (resuming from its current
/// size) and renames it to `destinationURL` — uniquified if taken — when the transfer completes.
struct SlskDownloadRequest: Sendable {
    let id: UUID
    let username: String
    /// Full remote path, backslash-separated, exactly as it appeared in the search result.
    let remotePath: String
    let size: UInt64
    let partURL: URL
    let destinationURL: URL
}

enum SlskDownloadState: Equatable, Sendable {
    case connecting
    case requested
    case queued(place: UInt32?)
    case transferring(received: UInt64, total: UInt64)
    case finished(URL)
    case failed(String)
    case cancelled
}

/// A Soulseek client covering connect/login/search/download.
///
/// One TCP connection to the central server carries login and search requests. Search *results*
/// arrive out-of-band from peers: either they connect to our listener directly, or — when they
/// can't reach us — the server relays a `ConnectToPeer` and we dial out and answer with
/// `PierceFireWall`. Both paths end in the same peer-message loop.
///
/// Downloads ride the same machinery: a `QueueUpload` goes to the peer over a message (`P`)
/// connection, the peer answers with a `TransferRequest` (on any P connection, possibly much
/// later), we allow it, and the file arrives on a separate `F` connection as raw bytes after a
/// token/offset exchange.
///
/// Private messages and user status ride the server connection; user info (description,
/// picture, slots) is asked of the peer directly, like a browse.
actor SoulseekClient {
    static let defaultServer = (host: "server.slsknet.org", port: UInt16(2242))
    private static let maxPeerConnections = 96
    private static let peerIdleTimeout: TimeInterval = 45
    /// A stalled transfer is given longer than an idle message connection before giving up.
    private static let transferIdleTimeout: TimeInterval = 60

    private let username: String
    private let password: String
    private let serverAddress: (host: String, port: UInt16)
    private let onEvent: @Sendable (SlskEvent) -> Void

    private var server: TCPConnection?
    private var listener: SlskListener?
    private var tasks: [Task<Void, Never>] = []
    private var peerTasks: [UUID: Task<Void, Never>] = [:]
    private var loginContinuation: CheckedContinuation<SlskLoginReply, Error>?
    private(set) var isLoggedIn = false

    // MARK: Download state

    private struct ActiveDownload {
        let request: SlskDownloadRequest
        var expectedSize: UInt64
        /// Token from the peer's `TransferRequest`; identifies the coming `F` connection.
        var transferToken: UInt32?
        /// The `F` connection while bytes are flowing, so a cancel can close it.
        var fileStream: (any SlskStream)?
        var finished = false
    }

    private var downloads: [UUID: ActiveDownload] = [:]
    /// Cancels that arrived before their `download` call did.
    private var cancelledDownloadIDs: Set<UUID> = []
    /// Open message connections by peer username, for sending requests.
    private var peerChannels: [String: any SlskStream] = [:]
    /// In-flight channel establishment, so parallel downloads to one user share a connection.
    private var channelTasks: [String: Task<(any SlskStream)?, Never>] = [:]
    /// Tokens from our `ConnectToPeer` requests, waiting for the peer to pierce our listener.
    /// The resumed value carries any bytes read past the pierce frame.
    private var pendingPierces: [UInt32: CheckedContinuation<(stream: any SlskStream, leftover: Data)?, Never>] = [:]
    private var pierceUsers: [UInt32: String] = [:]
    /// Pierce tokens whose connection belongs to an upload task, not the message loop.
    private var fileTransferPierceTokens: Set<UInt32> = []
    /// `GetPeerAddress` replies arrive on the server loop; waiters are keyed by username.
    private var addressWaiters: [String: [CheckedContinuation<(host: String, port: UInt16)?, Never>]] = [:]

    // MARK: Sharing state

    private var shares: SlskShareSnapshot = .empty
    private var hasParent = false
    private var adoptingParent = false

    private struct UploadJob {
        let id = UUID()
        let username: String
        let file: SlskSharedFile
        var started = false
    }

    private static let maxUploadSlots = 2
    private var uploadQueue: [UploadJob] = []
    private var activeUploadCount = 0
    /// Downloaders answer our upload `TransferRequest` with a `TransferResponse` by token.
    private var transferResponseWaiters: [UInt32: CheckedContinuation<SlskTransferResponse?, Never>] = [:]
    /// Total upload rate cap in bytes/s (nil = unlimited), and when the next chunk may go out.
    private var uploadLimit: Int?
    private var uploadPacer = ContinuousClock.now
    /// Users who get nothing from us: no search results, no browsing, no uploads.
    private var blockedUsers: Set<String> = []

    // MARK: Browse state

    /// People waiting for a user's share list (peer code 5), by request.
    private var browseWaiters: [UUID: (user: String, continuation: CheckedContinuation<SlskSharedFileList?, Never>)] = [:]

    // MARK: User info state

    /// What we tell peers who ask about us (peer code 16).
    private var ownDescription = ""
    private var ownPicture: Data?
    /// People waiting for a user's info (peer code 16), by request.
    private var userInfoWaiters: [UUID: (user: String, continuation: CheckedContinuation<SlskUserInfo?, Never>)] = [:]

    init(
        username: String,
        password: String,
        server: (host: String, port: UInt16) = SoulseekClient.defaultServer,
        onEvent: @escaping @Sendable (SlskEvent) -> Void
    ) {
        self.username = username
        self.password = password
        serverAddress = server
        self.onEvent = onEvent
    }

    // MARK: Connect / disconnect

    /// Connects, logs in, and leaves the client listening for peers. Throws with the server's
    /// reason ("INVALIDPASS", …) on login failure.
    func connect() async throws {
        guard server == nil else { return }

        let listenPort = startListener()
        let server = TCPConnection(host: serverAddress.host, port: serverAddress.port)
        self.server = server
        do {
            try await server.start(timeout: 20)
            try await server.send(SlskServerMessage.login(username: username, password: password))

            tasks.append(Task { await self.runServerLoop(server) })

            let reply = try await withCheckedThrowingContinuation { loginContinuation = $0 }
            guard reply.success else {
                throw SlskError(message: "Login failed: \(reply.greeting)")
            }

            try await server.send(SlskServerMessage.setWaitPort(listenPort))
            try await server.send(SlskServerMessage.setStatus(online: true))
            try await server.send(SlskServerMessage.sharedFoldersFiles(
                folders: UInt32(shares.folderCount), files: UInt32(shares.files.count)))

            // Join the distributed network as a leaf: ask for a parent, take no children.
            try await server.send(SlskServerMessage.branchRoot(username))
            try await server.send(SlskServerMessage.branchLevel(0))
            try await server.send(SlskServerMessage.acceptChildren(false))
            try await server.send(SlskServerMessage.haveNoParent(true))

            isLoggedIn = true
            onEvent(.connected(username: username, greeting: reply.greeting))
            tasks.append(Task { await self.runPingLoop(server) })
        } catch {
            await shutDown(reason: nil)
            throw error
        }
    }

    func disconnect() async {
        await shutDown(reason: nil)
    }

    private func shutDown(reason: String?) async {
        let wasLoggedIn = isLoggedIn
        isLoggedIn = false
        loginContinuation?.resume(throwing: SlskError(message: reason ?? "Disconnected"))
        loginContinuation = nil
        for continuation in pendingPierces.values { continuation.resume(returning: nil) }
        pendingPierces = [:]
        pierceUsers = [:]
        fileTransferPierceTokens = []
        for continuation in transferResponseWaiters.values { continuation.resume(returning: nil) }
        transferResponseWaiters = [:]
        for waiter in browseWaiters.values { waiter.continuation.resume(returning: nil) }
        browseWaiters = [:]
        for waiter in userInfoWaiters.values { waiter.continuation.resume(returning: nil) }
        userInfoWaiters = [:]
        for job in uploadQueue { onEvent(.uploadState(id: job.id, state: .failed(reason ?? "Disconnected"))) }
        uploadQueue = []
        activeUploadCount = 0
        hasParent = false
        adoptingParent = false
        for waiters in addressWaiters.values {
            for continuation in waiters { continuation.resume(returning: nil) }
        }
        addressWaiters = [:]
        for (id, download) in downloads where !download.finished {
            onEvent(.downloadState(id: id, state: .failed(reason ?? "Disconnected")))
        }
        downloads = [:]
        peerChannels = [:]
        channelTasks = [:]
        for task in tasks { task.cancel() }
        tasks = []
        for task in peerTasks.values { task.cancel() }
        peerTasks = [:]
        server?.cancel()
        server = nil
        listener?.cancel()
        listener = nil
        if wasLoggedIn { onEvent(.disconnected(reason: reason)) }
    }

    // MARK: Search

    func search(token: UInt32, query: String) async throws {
        guard isLoggedIn, let server else { throw SlskError(message: "Not connected") }
        try await server.send(SlskServerMessage.fileSearch(token: token, query: query))
    }

    /// A saved search; results arrive like any other search's, under `token`.
    func wishlistSearch(token: UInt32, query: String) async throws {
        guard isLoggedIn, let server else { throw SlskError(message: "Not connected") }
        try await server.send(SlskServerMessage.wishlistSearch(token: token, query: query))
    }

    // MARK: Browse

    /// Asks `user` for their whole share. Big shares can take a while to arrive.
    func browse(user: String) async throws -> SlskSharedFileList {
        guard isLoggedIn else { throw SlskError(message: "Not connected") }
        guard let channel = await channel(to: user) else { throw SlskError(message: "Couldn't connect to \(user)") }
        let id = UUID()
        let list = await withCheckedContinuation { (continuation: CheckedContinuation<SlskSharedFileList?, Never>) in
            // Waiting before the request goes out, so even an instant answer finds us.
            browseWaiters[id] = (user, continuation)
            Task {
                do {
                    try await channel.send(SlskPeerMessage.sharedFileListRequest())
                } catch {
                    self.finishBrowse(id, with: nil)
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(300))
                await self?.finishBrowse(id, with: nil)
            }
        }
        guard let list else { throw SlskError(message: "\(user) didn't send their file list") }
        return list
    }

    private func finishBrowse(_ id: UUID, with list: SlskSharedFileList?) {
        browseWaiters.removeValue(forKey: id)?.continuation.resume(returning: list)
    }

    private func receivedFileList(_ list: SlskSharedFileList) {
        for (id, waiter) in browseWaiters where waiter.user == list.username {
            finishBrowse(id, with: list)
        }
    }

    // MARK: Private messages

    /// Sends a private message. The server stores it if `user` is offline and hands it over
    /// when they next log in.
    func sendMessage(to user: String, text: String) async throws {
        guard isLoggedIn, let server else { throw SlskError(message: "Not connected") }
        try await server.send(SlskServerMessage.messageUser(username: user, message: text))
    }

    /// Every message is acknowledged, or the server sends it again at the next login — even
    /// a blocked user's, which is then dropped.
    private func receivedPrivateMessage(_ message: SlskPrivateMessage) async {
        try? await server?.send(SlskServerMessage.messageAcked(id: message.id))
        guard !blockedUsers.contains(message.username) else { return }
        onEvent(.privateMessage(message))
    }

    // MARK: User status and info

    /// Asks the server to keep us posted on `user`'s status; the first answer also brings
    /// their stats.
    func watch(user: String) async {
        guard isLoggedIn, let server else { return }
        try? await server.send(SlskServerMessage.watchUser(user))
    }

    func unwatch(user: String) async {
        guard isLoggedIn, let server else { return }
        try? await server.send(SlskServerMessage.unwatchUser(user))
    }

    /// Fresh status and stats for `user`; answers arrive as `.userStatus` / `.userStats`.
    func requestStatusAndStats(of user: String) async {
        guard isLoggedIn, let server else { return }
        try? await server.send(SlskServerMessage.getUserStatus(user))
        try? await server.send(SlskServerMessage.getUserStats(user))
    }

    /// What we answer when someone asks about us.
    func setOwnInfo(description: String, picture: Data?) {
        ownDescription = description
        ownPicture = picture
    }

    /// Asks `user` directly for their description, picture and upload slots.
    func userInfo(of user: String) async throws -> SlskUserInfo {
        guard isLoggedIn else { throw SlskError(message: "Not connected") }
        guard let channel = await channel(to: user) else { throw SlskError(message: "Couldn't connect to \(user)") }
        let id = UUID()
        let info = await withCheckedContinuation { (continuation: CheckedContinuation<SlskUserInfo?, Never>) in
            userInfoWaiters[id] = (user, continuation)
            Task {
                do {
                    try await channel.send(SlskPeerMessage.userInfoRequest())
                } catch {
                    self.finishUserInfo(id, with: nil)
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                await self?.finishUserInfo(id, with: nil)
            }
        }
        guard let info else { throw SlskError(message: "\(user) didn't answer") }
        return info
    }

    private func finishUserInfo(_ id: UUID, with info: SlskUserInfo?) {
        userInfoWaiters.removeValue(forKey: id)?.continuation.resume(returning: info)
    }

    private func receivedUserInfo(_ info: SlskUserInfo, from user: String) {
        for (id, waiter) in userInfoWaiters where waiter.user == user {
            finishUserInfo(id, with: info)
        }
    }

    // MARK: Limits

    /// Caps the total upload rate (bytes/s); nil or 0 lifts the cap.
    func setUploadLimit(_ bytesPerSecond: Int?) {
        uploadLimit = bytesPerSecond.flatMap { $0 > 0 ? $0 : nil }
    }

    /// Waits until `bytes` more may be sent under the cap. Shared by all uploads, so the cap is
    /// for the total, not per transfer.
    private func paceUpload(_ bytes: Int) async {
        guard let limit = uploadLimit else { return }
        let now = ContinuousClock.now
        let start = max(now, uploadPacer)
        uploadPacer = start + .seconds(Double(bytes) / Double(limit))
        if start > now { try? await Task.sleep(until: start, clock: .continuous) }
    }

    /// Replaces the block list; queued uploads to newly blocked users are dropped.
    func updateBlockedUsers(_ users: Set<String>) {
        blockedUsers = users
        for job in uploadQueue where !job.started && users.contains(job.username) {
            onEvent(.uploadState(id: job.id, state: .failed("Blocked")))
        }
        uploadQueue.removeAll { !$0.started && users.contains($0.username) }
    }

    // MARK: Sharing

    /// Swaps in a fresh share scan; the server's counts are updated when logged in.
    func updateShares(_ snapshot: SlskShareSnapshot) async {
        shares = snapshot
        guard isLoggedIn, let server else { return }
        try? await server.send(SlskServerMessage.sharedFoldersFiles(
            folders: UInt32(snapshot.folderCount), files: UInt32(snapshot.files.count)))
    }

    /// A search reached us (via our distributed parent or straight from the server):
    /// answer the searcher directly over a `P` connection when we have matches.
    private func handleSearchRequest(searcher: String, token: UInt32, query: String) {
        guard searcher != username, !shares.isEmpty, !blockedUsers.contains(searcher) else { return }
        let matches = shares.matches(query: query, limit: 100)
        guard !matches.isEmpty,
              let message = try? SlskPeerMessage.fileSearchResponse(
                  username: username, token: token, files: matches,
                  slotFree: activeUploadCount < Self.maxUploadSlots,
                  averageSpeed: 0,
                  queueLength: UInt32(uploadQueue.count))
        else { return }
        spawnPeerTask {
            guard let channel = await self.channel(to: searcher) else { return }
            try await channel.send(message)
        }
    }

    // MARK: Server loop

    private func runServerLoop(_ server: TCPConnection) async {
        var frames = SlskFrameBuffer()
        do {
            while let chunk = try await server.receive() {
                frames.append(chunk)
                while let frame = try frames.nextFrame() {
                    try await handleServerFrame(frame)
                }
            }
            await shutDown(reason: "Server closed the connection")
        } catch is CancellationError {
        } catch {
            await shutDown(reason: error.localizedDescription)
        }
    }

    private func handleServerFrame(_ frame: Data) async throws {
        var reader = SlskReader(frame)
        let code = try reader.u32()
        let payload = Data(frame.dropFirst(4))

        switch SlskServerCode(rawValue: code) {
        case .login:
            let reply = try SlskLoginReply(parsing: payload)
            loginContinuation?.resume(returning: reply)
            loginContinuation = nil
        case .getPeerAddress:
            guard let reply = try? SlskPeerAddressReply(parsing: payload) else { return }
            for waiter in addressWaiters.removeValue(forKey: reply.username) ?? [] {
                waiter.resume(returning: (host: reply.host, port: reply.port))
            }
        case .connectToPeer:
            guard let request = try? SlskConnectToPeer(parsing: payload),
                  request.connectionType == "P" || request.connectionType == "F" else { return }
            spawnPeerTask { try await self.runOutgoingPeer(request) }
        case .fileSearch:
            // The server delivers some searches directly (user/room searches, root duty).
            if let request = try? SlskServerSearchRequest(parsing: payload) {
                handleSearchRequest(searcher: request.username, token: request.token, query: request.query)
            }
        case .embeddedMessage:
            if let embedded = try? SlskEmbeddedMessage(parsing: payload),
               embedded.distributedCode == SlskDistribMessage.searchCode,
               case .search(let searcher, let token, let query)? = try? SlskDistribMessage.parseSearch(embedded.payload) {
                handleSearchRequest(searcher: searcher, token: token, query: query)
            }
        case .wishlistInterval:
            var reader = SlskReader(payload)
            if let seconds = try? reader.u32() { onEvent(.wishlistInterval(seconds: Int(seconds))) }
        case .messageUser:
            if let message = try? SlskPrivateMessage(parsing: payload) {
                await receivedPrivateMessage(message)
            }
        case .watchUser:
            if let reply = try? SlskWatchUserReply(parsing: payload) {
                onEvent(.userStatus(username: reply.username, status: reply.status, privileged: false))
                if let stats = reply.stats { onEvent(.userStats(username: reply.username, stats: stats)) }
            }
        case .getUserStatus:
            if let reply = try? SlskUserStatusReply(parsing: payload) {
                onEvent(.userStatus(username: reply.username, status: reply.status, privileged: reply.privileged))
            }
        case .getUserStats:
            if let reply = try? SlskUserStatsReply(parsing: payload) {
                onEvent(.userStats(username: reply.username, stats: reply.stats))
            }
        case .possibleParents:
            guard !hasParent, !adoptingParent,
                  let candidates = try? SlskPossibleParents(parsing: payload),
                  !candidates.parents.isEmpty else { return }
            adoptingParent = true
            let parents = candidates.parents
            spawnPeerTask { await self.adoptParent(from: parents) }
        default:
            break  // Room lists, parent speeds, wishlist interval, … — not needed.
        }
    }

    // MARK: Distributed network

    /// Connects to the first workable parent candidate and consumes its search stream until
    /// the connection drops, then asks the server for new candidates.
    private func adoptParent(from candidates: [(username: String, host: String, port: UInt16)]) async {
        defer { adoptingParent = false }
        for candidate in candidates where isLoggedIn && !hasParent && candidate.port > 0 {
            let connection = TCPConnection(host: candidate.host, port: candidate.port)
            do {
                try await connection.start(timeout: 6)
                try await connection.send(SlskPeerInit.peerInit(username: username, connectionType: "D"))
                try await runDistributedLoop(connection, parent: candidate.username)
            } catch {
                // Try the next candidate.
            }
            connection.cancel()
            if hasParent {
                // We had adopted this parent and lost it: start over with fresh candidates.
                hasParent = false
                if isLoggedIn, let server {
                    try? await server.send(SlskServerMessage.branchRoot(username))
                    try? await server.send(SlskServerMessage.branchLevel(0))
                    try? await server.send(SlskServerMessage.haveNoParent(true))
                }
                return
            }
        }
    }

    private func runDistributedLoop(_ connection: TCPConnection, parent: String) async throws {
        var frames = SlskFrameBuffer()
        while true {
            // Parents are quiet on a slow night; only the first message is held to a deadline.
            guard let frame = try await nextDistribFrame(&frames, on: connection, timeout: hasParent ? 600 : 20) else {
                return
            }
            switch try? SlskDistribMessage.parse(frame) {
            case .branchLevel(let level):
                if !hasParent {
                    hasParent = true
                    adoptingParent = false
                    try? await server?.send(SlskServerMessage.haveNoParent(false))
                }
                try? await server?.send(SlskServerMessage.branchLevel(UInt32(max(0, level) + 1)))
                if level == 0 {
                    // A level-0 parent is the branch root and won't send a BranchRoot message.
                    try? await server?.send(SlskServerMessage.branchRoot(parent))
                }
            case .branchRoot(let root):
                try? await server?.send(SlskServerMessage.branchRoot(root))
            case .search(let searcher, let token, let query):
                handleSearchRequest(searcher: searcher, token: token, query: query)
            case .embedded(let code, let payload):
                if code == SlskDistribMessage.searchCode,
                   case .search(let searcher, let token, let query)? = try? SlskDistribMessage.parseSearch(payload) {
                    handleSearchRequest(searcher: searcher, token: token, query: query)
                }
            default:
                break
            }
        }
    }

    private func nextDistribFrame(
        _ frames: inout SlskFrameBuffer, on connection: any SlskStream, timeout: TimeInterval
    ) async throws -> Data? {
        while true {
            if let frame = try frames.nextFrame() { return frame }
            guard let chunk = try await withSlskTimeout(timeout, on: connection) else { return nil }
            frames.append(chunk)
        }
    }

    private func runPingLoop(_ server: TCPConnection) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(55))
            guard !Task.isCancelled else { return }
            do {
                try await server.send(SlskServerMessage.ping())
            } catch {
                await shutDown(reason: "Connection lost")
                return
            }
        }
    }

    // MARK: Peer connections

    /// Starts listening for incoming peer connections; returns the bound port (0 when
    /// listening failed — searches then rely purely on server-relayed connections).
    private func startListener() -> UInt16 {
        guard let listener = SlskListener(preferredPort: 2234) else { return 0 }
        listener.start { [weak self] connection in
            guard let self else { return connection.cancel() }
            Task { await self.acceptIncomingPeer(connection) }
        }
        self.listener = listener
        return listener.port
    }

    private func acceptIncomingPeer(_ connection: SocketConnection) {
        spawnPeerTask { try await self.runIncomingPeer(connection) }
    }

    @discardableResult
    private func spawnPeerTask(_ body: @escaping @Sendable () async throws -> Void) -> Bool {
        guard peerTasks.count < Self.maxPeerConnections else { return false }
        let id = UUID()
        peerTasks[id] = Task {
            try? await body()
            self.peerTaskFinished(id)
        }
        return true
    }

    private func peerTaskFinished(_ id: UUID) {
        peerTasks[id] = nil
    }

    /// A peer connected to our listener: expect a peer-init frame, then peer messages —
    /// or, for an `F` init, raw file-transfer bytes.
    private func runIncomingPeer(_ connection: SocketConnection) async throws {
        var transferredOwnership = false
        defer { if !transferredOwnership { connection.cancel() } }
        var frames = SlskFrameBuffer()
        guard let first = try await nextFrame(&frames, on: connection) else { return }
        switch try SlskPeerInit.parse(first) {
        case .peerInit(let user, "P"):
            if peerChannels[user] == nil { peerChannels[user] = connection }
            defer { channelClosed(user, connection: connection) }
            try await runPeerMessageLoop(connection, frames: &frames, username: user)
        case .peerInit(_, "F"):
            await runFileConnection(connection, buffered: frames.drainRemaining())
        case .pierceFirewall(let token):
            if fileTransferPierceTokens.remove(token) != nil {
                // An upload task owns this connection from here on.
                if let continuation = pendingPierces.removeValue(forKey: token) {
                    continuation.resume(returning: (connection, frames.drainRemaining()))
                    transferredOwnership = true
                }
                return
            }
            let user = pierceUsers[token]
            if let continuation = pendingPierces.removeValue(forKey: token) {
                continuation.resume(returning: (connection, Data()))
            }
            if let user {
                defer { channelClosed(user, connection: connection) }
                try await runPeerMessageLoop(connection, frames: &frames, username: user)
            } else {
                try await runPeerMessageLoop(connection, frames: &frames, username: nil)
            }
        default:
            return  // "D" connections from others: we accept no distributed children.
        }
    }

    /// The server relayed a connection request: dial the peer and pierce their firewall.
    /// For `F` requests the peer then starts a file transfer on this connection.
    private func runOutgoingPeer(_ request: SlskConnectToPeer) async throws {
        let connection = TCPConnection(host: request.host, port: request.port)
        defer { connection.cancel() }
        try await connection.start(timeout: 10)
        try await connection.send(SlskPeerInit.pierceFirewall(token: request.token))
        if request.connectionType == "F" {
            await runFileConnection(connection, buffered: Data())
        } else {
            if peerChannels[request.username] == nil { peerChannels[request.username] = connection }
            defer { channelClosed(request.username, connection: connection) }
            var frames = SlskFrameBuffer()
            try await runPeerMessageLoop(connection, frames: &frames, username: request.username)
        }
    }

    private func runPeerMessageLoop(
        _ connection: any SlskStream,
        frames: inout SlskFrameBuffer,
        username: String?
    ) async throws {
        while let frame = try await nextFrame(&frames, on: connection) {
            var reader = SlskReader(frame)
            guard let code = try? reader.u32() else { continue }
            let payload = Data(frame.dropFirst(4))
            switch SlskPeerCode(rawValue: code) {
            case .fileSearchResponse:
                if let response = try? SlskSearchResponse(parsing: payload) {
                    onEvent(.searchResults(token: response.token, results: response.results))
                }
            case .transferRequest:
                if let request = try? SlskTransferRequest(parsing: payload) {
                    await handleTransferRequest(request, from: username, on: connection)
                }
            case .uploadDenied:
                if let denied = try? SlskUploadDenied(parsing: payload) {
                    handleUploadDenied(denied, from: username)
                }
            case .uploadFailed:
                if let failed = try? SlskUploadFailed(parsing: payload),
                   let id = findDownload(path: failed.path, username: username) {
                    onEvent(.downloadState(id: id, state: .failed("The uploader reported a failure")))
                }
            case .placeInQueueResponse:
                if let place = try? SlskPlaceInQueueResponse(parsing: payload),
                   let id = findDownload(path: place.path, username: username) {
                    onEvent(.downloadState(id: id, state: .queued(place: place.place)))
                }
            case .transferResponse:
                if let response = try? SlskTransferResponse(parsing: payload) {
                    transferResponseWaiters.removeValue(forKey: response.token)?.resume(returning: response)
                }
            case .queueUpload:
                if let request = try? SlskQueueUploadRequest(parsing: payload) {
                    await handleQueueUpload(request.path, from: username, on: connection)
                }
            case .sharedFileListRequest:
                let payload = username.map(blockedUsers.contains) == true ? SlskShareSnapshot.empty.browsePayload : shares.browsePayload
                try? await connection.send(SlskPeerMessage.sharedFileListResponse(browsePayload: payload))
            case .sharedFileListResponse:
                if let username, let list = try? SlskSharedFileList(parsing: payload, username: username) {
                    receivedFileList(list)
                }
            case .userInfoRequest:
                guard username.map(blockedUsers.contains) != true else { break }
                try? await connection.send(SlskPeerMessage.userInfoResponse(
                    description: ownDescription,
                    picture: ownPicture,
                    uploadSlots: UInt32(Self.maxUploadSlots),
                    queueLength: UInt32(uploadQueue.filter { !$0.started }.count),
                    slotFree: activeUploadCount < Self.maxUploadSlots))
            case .userInfoResponse:
                if let username, let info = try? SlskUserInfo(parsing: payload) {
                    receivedUserInfo(info, from: username)
                }
            case .placeInQueueRequest:
                if let request = try? SlskPlaceInQueueRequest(parsing: payload), let username {
                    let waiting = uploadQueue.filter { !$0.started }
                    if let place = waiting.firstIndex(where: { $0.username == username && $0.file.virtualPath == request.path }) {
                        try? await connection.send(SlskPeerMessage.placeInQueueResponse(
                            path: request.path, place: UInt32(place + 1)))
                    }
                }
            default:
                break
            }
        }
    }

    private func nextFrame(_ frames: inout SlskFrameBuffer, on connection: any SlskStream) async throws -> Data? {
        while true {
            if let frame = try frames.nextFrame() { return frame }
            guard let chunk = try await withSlskTimeout(Self.peerIdleTimeout, on: connection) else { return nil }
            frames.append(chunk)
        }
    }

    // MARK: Downloads

    /// Queues a download with the peer. Progress arrives as `.downloadState` events; the peer
    /// decides when the transfer actually starts (it may sit in their upload queue for a while).
    func download(_ request: SlskDownloadRequest) async {
        guard isLoggedIn else {
            onEvent(.downloadState(id: request.id, state: .failed("Not connected")))
            return
        }
        guard downloads[request.id] == nil, cancelledDownloadIDs.remove(request.id) == nil else { return }
        // A retry replaces any stale entry for the same file, so a late TransferRequest
        // can't be matched to a download the UI no longer shows.
        downloads = downloads.filter {
            $0.value.finished || $0.value.request.username != request.username
                || $0.value.request.remotePath != request.remotePath
        }
        downloads[request.id] = ActiveDownload(request: request, expectedSize: request.size)
        onEvent(.downloadState(id: request.id, state: .connecting))

        guard let channel = await channel(to: request.username) else {
            guard downloads[request.id] != nil else { return }  // disconnected or cancelled meanwhile
            onEvent(.downloadState(id: request.id, state: .failed("Can't reach \(request.username)")))
            return
        }
        guard downloads[request.id] != nil else { return }
        do {
            try await channel.send(SlskPeerMessage.queueUpload(path: request.remotePath))
            onEvent(.downloadState(id: request.id, state: .requested))
        } catch {
            onEvent(.downloadState(id: request.id, state: .failed("Couldn't request the file")))
        }
    }

    /// Forgets a download and closes its transfer if one is running. The peer gets no message
    /// for a queued file (the protocol has none); when it later offers the transfer,
    /// `handleTransferRequest` declines it. The partial file is deleted.
    func cancelDownload(_ id: UUID) {
        guard let download = downloads.removeValue(forKey: id) else {
            cancelledDownloadIDs.insert(id)
            return
        }
        guard !download.finished else { return }
        download.fileStream?.cancel()
        try? FileManager.default.removeItem(at: download.request.partURL)
    }

    /// The oldest live download matching a path the peer named (and the user, when known).
    private func findDownload(path: String, username: String?) -> UUID? {
        downloads.first { _, download in
            !download.finished && download.request.remotePath == path
                && (username == nil || download.request.username == username)
        }?.key
    }

    /// The peer is ready to upload: remember the transfer token so the coming `F` connection
    /// can be matched, and accept. Requests for nothing we asked for are declined.
    private func handleTransferRequest(
        _ request: SlskTransferRequest, from username: String?, on connection: any SlskStream
    ) async {
        guard request.direction == 1 else { return }
        guard let id = findDownload(path: request.path, username: username) else {
            try? await connection.send(
                SlskPeerMessage.transferResponse(token: request.token, allowed: false, reason: "Cancelled"))
            return
        }
        downloads[id]?.transferToken = request.token
        if request.size > 0 { downloads[id]?.expectedSize = request.size }
        try? await connection.send(SlskPeerMessage.transferResponse(token: request.token, allowed: true))
    }

    private func handleUploadDenied(_ denied: SlskUploadDenied, from username: String?) {
        guard let id = findDownload(path: denied.path, username: username) else { return }
        if denied.reason == "Queued" {
            onEvent(.downloadState(id: id, state: .queued(place: nil)))
        } else {
            onEvent(.downloadState(id: id, state: .failed(denied.reason)))
        }
    }

    // MARK: Uploads

    /// A peer queued one of our shared files. Unknown paths are denied; known ones wait for
    /// an upload slot.
    private func handleQueueUpload(_ path: String, from user: String?, on connection: any SlskStream) async {
        guard let user else { return }
        guard !blockedUsers.contains(user) else {
            try? await connection.send(SlskPeerMessage.uploadDenied(path: path, reason: "Banned"))
            return
        }
        guard let file = shares.filesByVirtualPath[path] else {
            try? await connection.send(SlskPeerMessage.uploadDenied(path: path, reason: "File not shared."))
            return
        }
        guard uploadQueue.count < 100 else {
            try? await connection.send(SlskPeerMessage.uploadDenied(path: path, reason: "Too many files"))
            return
        }
        guard !uploadQueue.contains(where: { $0.username == user && $0.file.virtualPath == path }) else { return }
        let job = UploadJob(username: user, file: file)
        uploadQueue.append(job)
        onEvent(.uploadStarted(id: job.id, username: user, virtualPath: path, size: file.size))
        onEvent(.uploadState(id: job.id, state: .waiting))
        pumpUploads()
    }

    private func pumpUploads() {
        while activeUploadCount < Self.maxUploadSlots,
              let index = uploadQueue.firstIndex(where: { !$0.started }) {
            uploadQueue[index].started = true
            let job = uploadQueue[index]
            activeUploadCount += 1
            guard spawnPeerTask({ await self.performUpload(job) }) else {
                finishUpload(job, state: .failed("Too many connections"))
                continue
            }
        }
    }

    private func finishUpload(_ job: UploadJob, state: SlskUploadState) {
        onEvent(.uploadState(id: job.id, state: state))
        uploadQueue.removeAll { $0.id == job.id }
        activeUploadCount = max(0, activeUploadCount - 1)
        pumpUploads()
    }

    /// One upload, start to finish: offer the transfer, wait for the downloader's go-ahead,
    /// open the `F` connection, honor their resume offset, and stream the file.
    private func performUpload(_ job: UploadJob) async {
        guard let channel = await channel(to: job.username) else {
            finishUpload(job, state: .failed("Can't reach \(job.username)"))
            return
        }
        let token = UInt32.random(in: 1 ..< UInt32.max)
        do {
            try await channel.send(SlskPeerMessage.transferRequest(
                uploadToken: token, path: job.file.virtualPath, size: job.file.size))
        } catch {
            finishUpload(job, state: .failed("Couldn't offer the file"))
            return
        }

        let response = await withCheckedContinuation { (continuation: CheckedContinuation<SlskTransferResponse?, Never>) in
            transferResponseWaiters[token] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                await self?.expireTransferResponse(token)
            }
        }
        guard let response else {
            finishUpload(job, state: .failed("No answer from \(job.username)"))
            return
        }
        guard response.allowed else {
            finishUpload(job, state: .failed(response.reason.isEmpty ? "Declined" : response.reason))
            return
        }

        guard let (stream, buffered) = await fileConnection(to: job.username) else {
            finishUpload(job, state: .failed("Couldn't open a transfer connection"))
            return
        }
        defer { stream.cancel() }
        do {
            var writer = SlskWriter()
            writer.u32(token)
            try await stream.send(writer.data)
            try await sendFile(job, over: stream, buffered: buffered)
            finishUpload(job, state: .finished)
        } catch {
            try? await channel.send(SlskPeerMessage.uploadFailed(path: job.file.virtualPath))
            finishUpload(job, state: .failed(error.localizedDescription))
        }
    }

    private func expireTransferResponse(_ token: UInt32) {
        transferResponseWaiters.removeValue(forKey: token)?.resume(returning: nil)
    }

    /// Opens an `F` connection to a downloader: direct dial first, else via a server relay
    /// (the peer then pierces our listener and the accept task hands the socket over).
    private func fileConnection(to user: String) async -> (stream: any SlskStream, buffered: Data)? {
        if let address = await peerAddress(of: user), address.port > 0 {
            let direct = TCPConnection(host: address.host, port: address.port)
            do {
                try await direct.start(timeout: 8)
                try await direct.send(SlskPeerInit.peerInit(username: username, connectionType: "F"))
                return (direct, Data())
            } catch {
                direct.cancel()
            }
        }
        guard let server else { return nil }
        let pierceToken = UInt32.random(in: 1 ..< UInt32.max)
        fileTransferPierceTokens.insert(pierceToken)
        try? await server.send(SlskServerMessage.connectToPeer(token: pierceToken, username: user, connectionType: "F"))
        let pierced = await withCheckedContinuation { (continuation: CheckedContinuation<(stream: any SlskStream, leftover: Data)?, Never>) in
            pendingPierces[pierceToken] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                await self?.expirePierce(pierceToken)
            }
        }
        fileTransferPierceTokens.remove(pierceToken)
        return pierced.map { ($0.stream, $0.leftover) }
    }

    /// Reads the downloader's resume offset, then streams the file from there.
    private func sendFile(_ job: UploadJob, over stream: any SlskStream, buffered: Data) async throws {
        var raw = buffered
        while raw.count < 8 {
            guard let chunk = try await withSlskTimeout(Self.peerIdleTimeout, on: stream) else {
                throw SlskError(message: "The downloader closed the connection")
            }
            raw.append(chunk)
        }
        var reader = SlskReader(raw)
        let offset = try reader.u64()
        guard offset <= job.file.size else { throw SlskError(message: "Bad resume offset") }

        let handle = try FileHandle(forReadingFrom: job.file.url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)

        var sent = offset
        var lastReport = ContinuousClock.now
        onEvent(.uploadState(id: job.id, state: .transferring(sent: sent, total: job.file.size)))
        while sent < job.file.size {
            // Smaller chunks under a speed cap, so the rate stays smooth.
            let chunkSize = uploadLimit.map { max(4 << 10, min(128 << 10, $0 / 4)) } ?? 128 << 10
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            await paceUpload(chunk.count)
            try await stream.send(chunk)
            sent += UInt64(chunk.count)
            let now = ContinuousClock.now
            if now - lastReport > .milliseconds(250) || sent >= job.file.size {
                lastReport = now
                onEvent(.uploadState(id: job.id, state: .transferring(sent: sent, total: job.file.size)))
            }
        }
        guard sent >= job.file.size else { throw SlskError(message: "File ended early") }
        // Let the downloader finish reading and close; their close is the real "done".
        _ = try? await withSlskTimeout(30, on: stream)
    }

    // MARK: Peer channels

    /// An open message connection to `user`, establishing one if needed. Concurrent requests
    /// (several files of one album) share the attempt.
    private func channel(to user: String) async -> (any SlskStream)? {
        if let existing = peerChannels[user] { return existing }
        if let inFlight = channelTasks[user] { return await inFlight.value }
        let task = Task { await self.establishChannel(to: user) }
        channelTasks[user] = task
        let result = await task.value
        channelTasks[user] = nil
        return result
    }

    /// Modern connection order: announce an indirect attempt to the server first, then try a
    /// direct dial; if that fails, wait for the peer to pierce our listener with the token.
    private func establishChannel(to user: String) async -> (any SlskStream)? {
        guard let server else { return nil }
        let token = UInt32.random(in: 1 ..< UInt32.max)
        pierceUsers[token] = user
        try? await server.send(SlskServerMessage.connectToPeer(token: token, username: user, connectionType: "P"))

        if let address = await peerAddress(of: user), address.port > 0 {
            let direct = TCPConnection(host: address.host, port: address.port)
            do {
                try await direct.start(timeout: 8)
                try await direct.send(SlskPeerInit.peerInit(username: username, connectionType: "P"))
                pierceUsers[token] = nil
                peerChannels[user] = direct
                spawnPeerTask {
                    var frames = SlskFrameBuffer()
                    try? await self.runPeerMessageLoop(direct, frames: &frames, username: user)
                    direct.cancel()
                    await self.channelClosed(user, connection: direct)
                }
                return direct
            } catch {
                direct.cancel()
            }
        }

        // The pierced connection's message loop runs in the accepting listener task.
        let pierced = await withCheckedContinuation { (continuation: CheckedContinuation<(stream: any SlskStream, leftover: Data)?, Never>) in
            pendingPierces[token] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                await self?.expirePierce(token)
            }
        }
        pierceUsers[token] = nil
        if let pierced { peerChannels[user] = pierced.stream }
        return pierced?.stream
    }

    private func expirePierce(_ token: UInt32) {
        pendingPierces.removeValue(forKey: token)?.resume(returning: nil)
    }

    private func channelClosed(_ user: String, connection: any SlskStream) {
        if peerChannels[user] === connection { peerChannels[user] = nil }
    }

    private func peerAddress(of user: String) async -> (host: String, port: UInt16)? {
        guard let server else { return nil }
        return await withCheckedContinuation { continuation in
            addressWaiters[user, default: []].append(continuation)
            Task { [weak self] in
                try? await server.send(SlskServerMessage.getPeerAddress(username: user))
                try? await Task.sleep(for: .seconds(8))
                await self?.expireAddressQuery(user)
            }
        }
    }

    private func expireAddressQuery(_ user: String) {
        for continuation in addressWaiters.removeValue(forKey: user) ?? [] {
            continuation.resume(returning: nil)
        }
    }

    // MARK: File connections

    /// Runs an established `F` connection: reads the raw transfer token, matches it to a
    /// download, answers with our resume offset, and streams the raw bytes that follow into
    /// the download's .part file.
    private func runFileConnection(_ connection: any SlskStream, buffered: Data) async {
        var matchedID: UUID?
        do {
            var raw = buffered
            while raw.count < 4 {
                guard let chunk = try await withSlskTimeout(Self.peerIdleTimeout, on: connection) else { return }
                raw.append(chunk)
            }
            var reader = SlskReader(raw)
            let token = try reader.u32()

            guard let id = downloads.first(where: { $0.value.transferToken == token && !$0.value.finished })?.key,
                  let download = downloads[id] else { return }
            matchedID = id
            downloads[id]?.fileStream = connection
            defer { downloads[id]?.fileStream = nil }

            let partURL = download.request.partURL
            try FileManager.default.createDirectory(
                at: partURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let offset = (try? FileManager.default.attributesOfItem(atPath: partURL.path)[.size] as? UInt64) ?? 0
            if !FileManager.default.fileExists(atPath: partURL.path) {
                FileManager.default.createFile(atPath: partURL.path, contents: nil)
            }
            var writer = SlskWriter()
            writer.u64(offset)
            try await connection.send(writer.data)

            let expected = max(download.expectedSize, 1)
            guard offset < expected else {
                completeDownload(id)  // everything already on disk from an earlier attempt
                return
            }

            let handle = try FileHandle(forWritingTo: partURL)
            defer { try? handle.close() }
            try handle.truncate(atOffset: offset)
            try handle.seek(toOffset: offset)

            var received = offset
            let leftover = Data(raw.dropFirst(4))
            if !leftover.isEmpty {
                try handle.write(contentsOf: leftover)
                received += UInt64(leftover.count)
            }
            onEvent(.downloadState(id: id, state: .transferring(received: received, total: expected)))

            var lastReport = ContinuousClock.now
            while received < expected {
                guard let chunk = try await withSlskTimeout(Self.transferIdleTimeout, on: connection) else { break }
                try handle.write(contentsOf: chunk)
                received += UInt64(chunk.count)
                let now = ContinuousClock.now
                if now - lastReport > .milliseconds(250) || received >= expected {
                    lastReport = now
                    onEvent(.downloadState(id: id, state: .transferring(received: min(received, expected), total: expected)))
                }
            }
            try handle.close()

            guard downloads[id] != nil else { return }  // cancelled
            if received >= expected {
                completeDownload(id)
            } else {
                onEvent(.downloadState(id: id, state: .failed("Transfer interrupted")))
            }
        } catch {
            if let matchedID, downloads[matchedID]?.finished == false {
                onEvent(.downloadState(id: matchedID, state: .failed("Transfer failed: \(error.localizedDescription)")))
            }
        }
    }

    /// Moves the finished .part file into place (never clobbering an existing file).
    private func completeDownload(_ id: UUID) {
        guard var download = downloads[id], !download.finished else { return }
        let destination = Self.availableURL(for: download.request.destinationURL)
        do {
            try FileManager.default.moveItem(at: download.request.partURL, to: destination)
            download.finished = true
            downloads[id] = download
            onEvent(.downloadState(id: id, state: .finished(destination)))
        } catch {
            onEvent(.downloadState(id: id, state: .failed("Couldn't move the finished file")))
        }
    }

    /// `url`, or "name 2.ext", "name 3.ext", … when something already sits there.
    static func availableURL(for url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for attempt in 2 ... 99 {
            var candidate = folder.appendingPathComponent("\(base) \(attempt)")
            if !ext.isEmpty { candidate = candidate.appendingPathExtension(ext) }
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }
}

/// Receives with an idle deadline; a quiet peer connection is closed rather than kept forever.
private func withSlskTimeout(_ seconds: TimeInterval, on connection: any SlskStream) async throws -> Data? {
    try await withThrowingTaskGroup(of: Data?.self) { group in
        group.addTask { try await connection.receive() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw SlskError(message: "peer idle timeout")
        }
        defer { group.cancelAll() }
        return try await group.next() ?? nil
    }
}

// MARK: TCP

/// Minimal async wrapper around `NWConnection`, used for all outbound connections.
final class TCPConnection: SlskStream, @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var startContinuation: CheckedContinuation<Void, Error>?

    init(host: String, port: UInt16) {
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 2242,
            using: .tcp
        )
    }

    func start(timeout: TimeInterval) async throws {
        let deadline = Task {
            try await Task.sleep(for: .seconds(timeout))
            self.finishStart(.failure(SlskError(message: "connection timed out")))
            self.connection.cancel()
        }
        defer { deadline.cancel() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            startContinuation = continuation
            lock.unlock()
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.finishStart(.success(()))
                case .failed(let error):
                    self?.finishStart(.failure(error))
                case .cancelled:
                    self?.finishStart(.failure(SlskError(message: "connection cancelled")))
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
        }
    }

    private func finishStart(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = startContinuation
        startContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// One chunk of whatever is available; `nil` on a clean close.
    func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 128 << 10) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func cancel() {
        finishStart(.failure(SlskError(message: "connection cancelled")))
        connection.cancel()
    }
}
