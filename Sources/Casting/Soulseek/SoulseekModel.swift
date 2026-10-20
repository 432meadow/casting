import AppKit
import Foundation
import Observation
import Security

/// One row in the downloads list.
struct SoulseekDownload: Identifiable {
    let id: UUID
    let username: String
    let remotePath: String
    let size: UInt64
    let partURL: URL
    /// Where the file lands; updated to the actual URL when the transfer finishes.
    var localURL: URL
    var state: SlskDownloadState = .connecting

    var fileName: String { localURL.lastPathComponent }
    var isActive: Bool {
        switch state {
        case .finished, .failed, .cancelled: false
        default: true
        }
    }
}

/// One row in the uploads list (files other users fetch from our shared folder).
struct SoulseekUpload: Identifiable {
    let id: UUID
    let username: String
    let remotePath: String
    let size: UInt64
    var state: SlskUploadState = .waiting

    var fileName: String { String(remotePath.split(separator: "\\").last ?? "") }
    var isActive: Bool {
        switch state {
        case .finished, .failed: false
        default: true
        }
    }
}

/// What casting knows about another user: server status and stats, and what they told us.
struct SoulseekUserDetails {
    enum InfoState {
        case notRequested
        case loading
        case loaded(SlskUserInfo)
        case failed(String)
    }

    var status: SlskUserStatus?
    var privileged = false
    var stats: SlskUserStats?
    var info: InfoState = .notRequested
}

/// The user an info sheet is showing.
struct SoulseekUserSheet: Identifiable {
    let user: String
    var id: String { user }
}

/// UI-facing Soulseek state: credentials, connection status, and the current search.
@MainActor
@Observable
final class SoulseekModel {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected(user: String)
        case failed(String)
    }

    /// The Soulseek view's tabs; kept here so right-click menus anywhere can switch tabs.
    enum Pane: Hashable {
        case search, wishlist, browse, messages, downloads
    }

    var pane: Pane = .search

    var username: String = UserDefaults.standard.string(forKey: "soulseek.username") ?? "" {
        didSet {
            guard username != oldValue else { return }
            UserDefaults.standard.set(username, forKey: "soulseek.username")
            if case .disconnected = state {} else { disconnect() }
        }
    }

    var password: String = Keychain.string(service: SoulseekModel.keychainService, account: SoulseekModel.keychainAccount) ?? "" {
        didSet {
            guard password != oldValue else { return }
            if password.isEmpty {
                Keychain.delete(service: Self.keychainService, account: Self.keychainAccount)
            } else {
                Keychain.set(password, service: Self.keychainService, account: Self.keychainAccount)
            }
            if case .disconnected = state {} else { disconnect() }
        }
    }

    private(set) var state: ConnectionState = .disconnected {
        didSet {
            if case .failed(let reason) = state, state != oldValue { EventLog.shared.log("Soulseek: \(reason)") }
        }
    }
    private(set) var results: [SlskSearchResult] = []
    private(set) var resultUserCount = 0
    /// The query the current results belong to; nil before the first search.
    private(set) var activeQuery: String?
    var query = ""

    private(set) var downloads: [SoulseekDownload] = []
    private(set) var uploads: [SoulseekUpload] = []
    /// Called (on the main actor) with completed download folders; returns false while the
    /// library can't take them yet (a scan is running), and the import is retried.
    @ObservationIgnored var importFolders: (([URL]) -> Bool)?
    /// Audio details for shared files casting already knows (its own library), keyed by path.
    /// Called on the main actor right before a scan.
    @ObservationIgnored var libraryAttributes: (() -> [String: SlskFileAttributes])?

    // MARK: Sharing state

    enum ShareState: Equatable {
        case notSharing
        case scanning
        case ready(files: Int, folders: Int)
        case failed(String)
    }

    private(set) var shareState: ShareState = .notSharing

    /// The folder other users can search and fetch from; empty = sharing off.
    var sharedFolderPath: String = UserDefaults.standard.string(forKey: "soulseek.sharedFolder") ?? "" {
        didSet {
            guard sharedFolderPath != oldValue else { return }
            UserDefaults.standard.set(sharedFolderPath, forKey: "soulseek.sharedFolder")
            rescanShares()
        }
    }

    private var shareSnapshot = SlskShareSnapshot.empty
    private var scanTask: Task<Void, Never>?

    var downloadFolderPath: String = UserDefaults.standard.string(forKey: "soulseek.downloadFolder")
        ?? SoulseekModel.defaultDownloadFolder {
        didSet { UserDefaults.standard.set(downloadFolderPath, forKey: "soulseek.downloadFolder") }
    }

    static var defaultDownloadFolder: String {
        FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Soulseek").path
            ?? NSString("~/Music/Soulseek").expandingTildeInPath
    }

    var hasCredentials: Bool { !username.isEmpty && !password.isEmpty }

    private static let keychainService = "casting.soulseek"
    private static let keychainAccount = "password"
    private static let maxResults = 2500

    // MARK: Result filters

    /// Narrows the results shown (search, wishlist and browse alike).
    enum FormatFilter: String, CaseIterable, Identifiable {
        case any, lossless, kbps320, kbps256, kbps192

        var id: Self { self }

        var title: String {
            switch self {
            case .any: "Any Format"
            case .lossless: "Lossless"
            case .kbps320: "320 kbps or Better"
            case .kbps256: "256 kbps or Better"
            case .kbps192: "192 kbps or Better"
            }
        }

        func matches(_ result: SlskSearchResult) -> Bool {
            let minimum: Int
            switch self {
            case .any: return true
            case .lossless: return result.isLossless
            case .kbps320: minimum = 320
            case .kbps256: minimum = 256
            case .kbps192: minimum = 192
            }
            // VBR files report their average, so a V0 (≈245) passes 192 and 256 only if it's high enough.
            return result.isLossless || (result.bitrate ?? 0) >= minimum
        }
    }

    var filterText = ""
    var formatFilter: FormatFilter = FormatFilter(rawValue: UserDefaults.standard.string(forKey: "soulseek.formatFilter") ?? "") ?? .any {
        didSet { UserDefaults.standard.set(formatFilter.rawValue, forKey: "soulseek.formatFilter") }
    }
    var freeSlotsOnly: Bool = UserDefaults.standard.bool(forKey: "soulseek.freeSlotsOnly") {
        didSet { UserDefaults.standard.set(freeSlotsOnly, forKey: "soulseek.freeSlotsOnly") }
    }
    var groupByFolder: Bool = UserDefaults.standard.bool(forKey: "soulseek.groupByFolder") {
        didSet { UserDefaults.standard.set(groupByFolder, forKey: "soulseek.groupByFolder") }
    }

    var hasActiveFilters: Bool {
        !filterText.trimmingCharacters(in: .whitespaces).isEmpty || formatFilter != .any || freeSlotsOnly
    }

    /// `results` minus blocked users and whatever the filters exclude.
    func filtered(_ results: [SlskSearchResult]) -> [SlskSearchResult] {
        var include: [String] = []
        var exclude: [String] = []
        for word in filterText.lowercased().split(separator: " ") {
            if word.hasPrefix("-"), word.count > 1 { exclude.append(String(word.dropFirst())) } else { include.append(String(word)) }
        }
        let blocked = Set(blockedUsers)
        return results.filter { result in
            guard !blocked.contains(result.username), formatFilter.matches(result) else { return false }
            if freeSlotsOnly, !result.slotFree { return false }
            guard !include.isEmpty || !exclude.isEmpty else { return true }
            let path = result.path.lowercased()
            return include.allSatisfy(path.contains) && !exclude.contains(where: path.contains)
        }
    }

    // MARK: Blocked users

    var blockedUsers: [String] = UserDefaults.standard.stringArray(forKey: "soulseek.blockedUsers") ?? [] {
        didSet {
            UserDefaults.standard.set(blockedUsers, forKey: "soulseek.blockedUsers")
            let users = Set(blockedUsers)
            Task { await client?.updateBlockedUsers(users) }
        }
    }

    func block(_ user: String) {
        guard !blockedUsers.contains(user) else { return }
        blockedUsers.append(user)
        blockedUsers.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func unblock(_ user: String) {
        blockedUsers.removeAll { $0 == user }
    }

    // MARK: Upload speed limit

    var limitsUploadSpeed: Bool = UserDefaults.standard.bool(forKey: "soulseek.limitUploads") {
        didSet {
            UserDefaults.standard.set(limitsUploadSpeed, forKey: "soulseek.limitUploads")
            pushUploadLimit()
        }
    }
    /// KB/s, for all uploads together.
    var uploadLimitKBps: Int = UserDefaults.standard.object(forKey: "soulseek.uploadLimitKBps") as? Int ?? 500 {
        didSet {
            UserDefaults.standard.set(uploadLimitKBps, forKey: "soulseek.uploadLimitKBps")
            pushUploadLimit()
        }
    }

    private func pushUploadLimit() {
        let limit = limitsUploadSpeed ? max(1, uploadLimitKBps) * 1024 : nil
        Task { await client?.setUploadLimit(limit) }
    }

    // MARK: Connection and notifications

    var connectsAtLaunch: Bool = UserDefaults.standard.bool(forKey: "soulseek.connectAtLaunch") {
        didSet { UserDefaults.standard.set(connectsAtLaunch, forKey: "soulseek.connectAtLaunch") }
    }
    var postsNotifications: Bool = UserDefaults.standard.object(forKey: "soulseek.notifications") as? Bool ?? true {
        didSet { UserDefaults.standard.set(postsNotifications, forKey: "soulseek.notifications") }
    }
    var postsMessageNotifications: Bool = UserDefaults.standard.object(forKey: "soulseek.messageNotifications") as? Bool ?? true {
        didSet { UserDefaults.standard.set(postsMessageNotifications, forKey: "soulseek.messageNotifications") }
    }

    // MARK: Private messages

    let chats: SoulseekChats
    /// The conversation picked in the Messages tab.
    var selectedConversation: String? {
        didSet { markSelectedConversationRead() }
    }
    /// True while the Messages tab is on screen; messages to the selected conversation then
    /// arrive already read.
    var isShowingMessages = false {
        didSet { markSelectedConversationRead() }
    }
    @ObservationIgnored private var messageNotifyTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingNotifications: [String: [SlskPrivateMessage]] = [:]

    private var isReadingSelectedConversation: Bool {
        isShowingMessages && NSApp?.isActive != false
    }

    private func markSelectedConversationRead() {
        if isReadingSelectedConversation, let user = selectedConversation { chats.markRead(user) }
    }

    /// Opens (or starts) the conversation with `user` in the Messages tab.
    func message(_ user: String) {
        let user = user.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty else { return }
        chats.open(user)
        selectedConversation = user
        pane = .messages
        watch(user)
    }

    func send(_ text: String, to user: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, hasCredentials else { return }
        let id = chats.addOutgoing(text, to: user)
        connect()
        Task {
            await waitForConnection()
            guard let client, case .connected = state else {
                chats.markFailed(id, in: user)
                return
            }
            do {
                try await client.sendMessage(to: user, text: text)
            } catch {
                chats.markFailed(id, in: user)
            }
        }
    }

    func removeConversation(_ user: String) {
        chats.remove(user)
        if selectedConversation == user { selectedConversation = nil }
    }

    private func receive(_ message: SlskPrivateMessage) {
        guard !blockedUsers.contains(message.username) else { return }
        let reading = isReadingSelectedConversation && selectedConversation == message.username
        chats.receive(message, unread: !reading)
        if userDetails[message.username]?.status == nil { watch(message.username) }
        guard postsMessageNotifications, !reading else { return }
        // Offline messages arrive in a burst at login: one notification per sender.
        pendingNotifications[message.username, default: []].append(message)
        guard messageNotifyTasks[message.username] == nil else { return }
        let user = message.username
        messageNotifyTasks[user] = Task {
            try? await Task.sleep(for: .seconds(1.5))
            messageNotifyTasks[user] = nil
            let messages = pendingNotifications.removeValue(forKey: user) ?? []
            guard let last = messages.last else { return }
            let offline = messages.contains { !$0.isNew }
            if messages.count == 1 {
                Notifier.post(title: offline ? "\(user) (while you were away)" : user, body: last.message)
            } else {
                Notifier.post(title: user, body: "\(messages.count) new messages\(offline ? " while you were away" : "") — latest: \(last.message)")
            }
        }
    }

    // MARK: User info

    /// Shown to other users who look us up (Settings ▸ Soulseek).
    var userDescription: String = UserDefaults.standard.string(forKey: "soulseek.userDescription") ?? "" {
        didSet {
            guard userDescription != oldValue else { return }
            UserDefaults.standard.set(userDescription, forKey: "soulseek.userDescription")
            let description = userDescription
            Task { await client?.setOwnInfo(description: description, picture: nil) }
        }
    }

    private(set) var userDetails: [String: SoulseekUserDetails] = [:]
    var userSheet: SoulseekUserSheet?
    @ObservationIgnored private var watchedUsers = Set<String>()

    /// Opens the info sheet for `user` and asks the server and the user for fresh details.
    func showUserInfo(_ user: String) {
        let user = user.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty else { return }
        userSheet = SoulseekUserSheet(user: user)
        requestUserInfo(user)
    }

    func requestUserInfo(_ user: String) {
        guard hasCredentials else { return }
        userDetails[user, default: SoulseekUserDetails()].info = .loading
        connect()
        Task {
            await waitForConnection()
            guard let client, case .connected = state else {
                userDetails[user, default: SoulseekUserDetails()].info = .failed("Not connected")
                return
            }
            watch(user)
            await client.requestStatusAndStats(of: user)
            do {
                let info = try await client.userInfo(of: user)
                userDetails[user, default: SoulseekUserDetails()].info = .loaded(info)
            } catch {
                userDetails[user, default: SoulseekUserDetails()].info = .failed(error.localizedDescription)
            }
        }
    }

    /// Keeps a user's online status current (conversations and info sheets).
    private func watch(_ user: String) {
        guard let client, case .connected = state, watchedUsers.insert(user).inserted else { return }
        Task { await client.watch(user: user) }
    }

    // MARK: Browsing a user

    enum BrowseState {
        case idle
        case loading(user: String)
        case loaded(SlskSharedFileList)
        case failed(user: String, reason: String)
    }

    private(set) var browseState: BrowseState = .idle
    var browseUser = ""
    private var browseTask: Task<Void, Never>?

    /// Fetches a user's whole share for the Browse tab.
    func browse(user: String) {
        let user = user.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty, hasCredentials else { return }
        browseUser = user
        pane = .browse
        browseState = .loading(user: user)
        browseTask?.cancel()
        connect()
        browseTask = Task {
            await waitForConnection()
            guard let client, case .connected = state else {
                browseState = .failed(user: user, reason: "Not connected")
                return
            }
            do {
                let list = try await client.browse(user: user)
                guard !Task.isCancelled else { return }
                browseState = .loaded(list)
            } catch {
                guard !Task.isCancelled else { return }
                browseState = .failed(user: user, reason: error.localizedDescription)
            }
        }
    }

    // MARK: Wishlist

    /// Saved searches, repeated in the background while connected.
    var wishlist: [String] = UserDefaults.standard.stringArray(forKey: "soulseek.wishlist") ?? [] {
        didSet { UserDefaults.standard.set(wishlist, forKey: "soulseek.wishlist") }
    }
    /// Everything each saved search has found this session.
    private(set) var wishlistResults: [String: [SlskSearchResult]] = [:]
    /// Results found since the item was last looked at.
    private(set) var wishlistNewCounts: [String: Int] = [:]
    private(set) var wishlistLastSearched: [String: Date] = [:]
    /// The server says how often (code 104); 12 minutes until it does.
    private(set) var wishlistInterval = 720
    private var wishlistTokens: [UInt32: String] = [:]
    private var wishlistSeen: [String: Set<String>] = [:]
    private var wishlistTask: Task<Void, Never>?
    private var wishlistCursor = 0
    private var wishlistNotifyTasks: [String: Task<Void, Never>] = [:]
    private static let maxWishlistResults = 1000

    func addToWishlist(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !wishlist.contains(where: { $0.caseInsensitiveCompare(query) == .orderedSame }) else { return }
        wishlist.append(query)
        searchWishlistItem(query)
    }

    func removeFromWishlist(_ query: String) {
        wishlist.removeAll { $0 == query }
        wishlistResults[query] = nil
        wishlistNewCounts[query] = nil
        wishlistSeen[query] = nil
        wishlistLastSearched[query] = nil
    }

    func markWishlistSeen(_ query: String) {
        if wishlistNewCounts[query] != nil { wishlistNewCounts[query] = nil }
    }

    var wishlistNewTotal: Int { wishlistNewCounts.values.reduce(0, +) }

    /// Runs one saved search now (if connected).
    func searchWishlistItem(_ query: String) {
        guard let client, case .connected = state else { return }
        let token = UInt32.random(in: 1 ..< UInt32.max)
        wishlistTokens[token] = query
        wishlistLastSearched[query] = Date()
        Task { try? await client.wishlistSearch(token: token, query: query) }
    }

    /// One saved search per interval, round-robin, while connected.
    private func startWishlistLoop() {
        wishlistTask?.cancel()
        wishlistTask = Task {
            try? await Task.sleep(for: .seconds(20))  // let login settle
            while !Task.isCancelled {
                if !wishlist.isEmpty {
                    wishlistCursor %= wishlist.count
                    searchWishlistItem(wishlist[wishlistCursor])
                    wishlistCursor += 1
                }
                try? await Task.sleep(for: .seconds(max(60, wishlistInterval)))
            }
        }
    }

    private func receiveWishlistResults(_ batch: [SlskSearchResult], for query: String) {
        var existing = wishlistResults[query] ?? []
        var seen = wishlistSeen[query] ?? []
        var added = 0
        for var result in batch where existing.count < Self.maxWishlistResults {
            guard seen.insert(result.username + "\u{1}" + result.path).inserted else { continue }
            result.id = existing.count
            existing.append(result)
            added += 1
        }
        guard added > 0 else { return }
        wishlistResults[query] = existing
        wishlistSeen[query] = seen
        wishlistNewCounts[query, default: 0] += added
        // Results trickle in for a while; one notification per round.
        guard postsNotifications, wishlistNotifyTasks[query] == nil else { return }
        wishlistNotifyTasks[query] = Task {
            try? await Task.sleep(for: .seconds(20))
            wishlistNotifyTasks[query] = nil
            if let count = wishlistNewCounts[query], count > 0 {
                Notifier.post(title: "Wishlist: “\(query)”", body: "\(count.formatted()) new \(count == 1 ? "result" : "results") on Soulseek.")
            }
        }
    }

    private var client: SoulseekClient?
    private var currentToken: UInt32 = 0
    private var resultUsers = Set<String>()
    private var pendingImportFolders = Set<URL>()
    private var importTask: Task<Void, Never>?

    // MARK: Connection

    /// `chats` nil loads the saved conversations.
    init(chats: SoulseekChats? = nil) {
        self.chats = chats ?? SoulseekChats()
    }

    func connect() {
        guard hasCredentials, state != .connecting else { return }
        if case .connected = state { return }

        state = .connecting
        let client = SoulseekClient(username: username, password: password) { [weak self] event in
            Task { @MainActor [weak self] in self?.handle(event) }
        }
        self.client = client
        if !sharedFolderPath.isEmpty, shareSnapshot.isEmpty, shareState != .scanning {
            rescanShares()  // pushes to the client when the scan lands
        }
        let blocked = Set(blockedUsers)
        let uploadLimit = limitsUploadSpeed ? max(1, uploadLimitKBps) * 1024 : nil
        let description = userDescription
        Task {
            do {
                await client.updateShares(shareSnapshot)
                await client.updateBlockedUsers(blocked)
                await client.setUploadLimit(uploadLimit)
                await client.setOwnInfo(description: description, picture: nil)
                try await client.connect()
            } catch {
                await client.disconnect()
                if self.client === client {
                    self.client = nil
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    func disconnect() {
        let client = client
        self.client = nil
        wishlistTask?.cancel()
        forgetUserStatuses()
        state = .disconnected
        Task { await client?.disconnect() }
    }

    private func handle(_ event: SlskEvent) {
        switch event {
        case .connected(let user, _):
            state = .connected(user: user)
            startWishlistLoop()
            for conversation in chats.conversations { watch(conversation.user) }
        case .disconnected(let reason):
            guard client != nil else { return }  // explicit disconnect already updated state
            client = nil
            wishlistTask?.cancel()
            forgetUserStatuses()
            state = reason.map { .failed($0) } ?? .disconnected
        case .privateMessage(let message):
            receive(message)
        case .userStatus(let user, let status, let privileged):
            userDetails[user, default: SoulseekUserDetails()].status = status
            userDetails[user, default: SoulseekUserDetails()].privileged = privileged
        case .userStats(let user, let stats):
            userDetails[user, default: SoulseekUserDetails()].stats = stats
        case .wishlistInterval(let seconds):
            if seconds > 0 { wishlistInterval = seconds }
        case .searchResults(let token, let batch):
            if let query = wishlistTokens[token] {
                receiveWishlistResults(batch, for: query)
                return
            }
            guard token == currentToken, results.count < Self.maxResults else { return }
            var renumbered = batch
            for index in renumbered.indices {
                renumbered[index].id = results.count + index
            }
            results.append(contentsOf: renumbered.prefix(Self.maxResults - results.count))
            if let user = batch.first?.username {
                resultUsers.insert(user)
                resultUserCount = resultUsers.count
            }
        case .downloadState(let id, let newState):
            guard let index = downloads.firstIndex(where: { $0.id == id }),
                  downloads[index].state != .cancelled else { return }
            downloads[index].state = newState
            if case .finished(let url) = newState {
                downloads[index].localURL = url
                scheduleImport(of: url.deletingLastPathComponent())
            }
        case .uploadStarted(let id, let username, let path, let size):
            uploads.append(SoulseekUpload(id: id, username: username, remotePath: path, size: size))
            // Keep the history bounded; drop the oldest finished rows first.
            while uploads.count > 200, let oldest = uploads.firstIndex(where: { !$0.isActive }) {
                uploads.remove(at: oldest)
            }
        case .uploadState(let id, let newState):
            guard let index = uploads.firstIndex(where: { $0.id == id }) else { return }
            uploads[index].state = newState
        }
    }

    /// Statuses go stale offline; the server resends them for watched users at the next login.
    private func forgetUserStatuses() {
        watchedUsers = []
        for user in userDetails.keys { userDetails[user]?.status = nil }
    }

    // MARK: Sharing

    func chooseSharedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Share"
        panel.message = "Other Soulseek users can search this folder and download from it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sharedFolderPath = url.path  // didSet rescans
    }

    func stopSharing() {
        sharedFolderPath = ""
    }

    /// Rescans the shared folder off the main thread and hands the result to the client.
    func rescanShares() {
        scanTask?.cancel()
        guard !sharedFolderPath.isEmpty else {
            shareSnapshot = .empty
            shareState = .notSharing
            Task { await client?.updateShares(.empty) }
            return
        }
        let folder = URL(fileURLWithPath: sharedFolderPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            shareState = .failed("The shared folder can't be found")
            return
        }
        shareState = .scanning
        let known = libraryAttributes?() ?? [:]
        scanTask = Task {
            let snapshot = await Task.detached(priority: .utility) {
                SlskShareScanner.scan(folder: folder) { known[$0] }
            }.value
            guard !Task.isCancelled else { return }
            shareSnapshot = snapshot
            shareState = .ready(files: snapshot.files.count, folders: snapshot.folderCount)
            await client?.updateShares(snapshot)
        }
    }

    func clearInactiveUploads() {
        uploads.removeAll { !$0.isActive }
    }

    var hasInactiveUploads: Bool { uploads.contains { !$0.isActive } }
    var activeDownloadCount: Int { downloads.lazy.filter(\.isActive).count }

    var shareStatusText: String {
        switch shareState {
        case .notSharing: "Not sharing — other users see an empty share"
        case .scanning: "Scanning the shared folder…"
        case .ready(let files, let folders): "Sharing \(files.formatted()) files in \(folders.formatted()) folders"
        case .failed(let reason): reason
        }
    }

    // MARK: Search

    func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, hasCredentials else { return }

        results = []
        resultUsers = []
        resultUserCount = 0
        activeQuery = text
        currentToken = UInt32.random(in: 1 ..< UInt32.max)
        let token = currentToken

        connect()
        Task {
            guard let client else { return }
            await waitForConnection()  // connect() may still be logging in
            guard case .connected = state else { return }
            do {
                try await client.search(token: token, query: text)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func waitForConnection() async {
        for _ in 0 ..< 100 {
            if case .connected = state { return }
            if case .failed = state { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    // MARK: Downloads

    func download(_ selectedResults: [SlskSearchResult]) {
        guard !selectedResults.isEmpty else { return }
        connect()
        for result in selectedResults {
            enqueue(username: result.username, remotePath: result.path, size: result.size)
        }
    }

    /// Re-requests a finished or failed download; a leftover .part file resumes where it stopped.
    func retry(_ id: SoulseekDownload.ID) {
        guard let index = downloads.firstIndex(where: { $0.id == id }), !downloads[index].isActive else { return }
        let item = downloads.remove(at: index)
        connect()
        enqueue(username: item.username, remotePath: item.remotePath, size: item.size)
    }

    /// Stops an active download and throws away what arrived so far.
    func cancel(_ ids: [SoulseekDownload.ID]) {
        for id in ids {
            guard let index = downloads.firstIndex(where: { $0.id == id }), downloads[index].isActive else { continue }
            downloads[index].state = .cancelled
            if let client {
                Task { await client.cancelDownload(id) }
            } else {
                try? FileManager.default.removeItem(at: downloads[index].partURL)
            }
        }
    }

    func cancelAllDownloads() {
        cancel(downloads.filter(\.isActive).map(\.id))
    }

    func remove(_ id: SoulseekDownload.ID) {
        downloads.removeAll { $0.id == id && !$0.isActive }
    }

    enum DownloadSort: String, CaseIterable, Identifiable {
        case newestFirst, folder

        var id: Self { self }

        var title: String {
            switch self {
            case .newestFirst: "Newest First"
            case .folder: "By Folder"
            }
        }
    }

    var downloadSort: DownloadSort = DownloadSort(rawValue: UserDefaults.standard.string(forKey: "soulseek.downloadSort") ?? "") ?? .newestFirst {
        didSet { UserDefaults.standard.set(downloadSort.rawValue, forKey: "soulseek.downloadSort") }
    }

    /// Downloads that land in one local folder (usually one album).
    struct DownloadFolder: Identifiable {
        let url: URL
        var downloads: [SoulseekDownload]

        var id: URL { url }
        var name: String { url.lastPathComponent }
        var users: [String] {
            var seen = Set<String>()
            return downloads.map(\.username).filter { seen.insert($0).inserted }
        }
    }

    /// Downloads grouped by local folder, folders and files in name order.
    var downloadFolders: [DownloadFolder] {
        Dictionary(grouping: downloads) { $0.localURL.deletingLastPathComponent() }
            .map { url, downloads in
                DownloadFolder(url: url, downloads: downloads.sorted {
                    $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
                })
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func clearInactiveDownloads() {
        downloads.removeAll { !$0.isActive }
    }

    var hasInactiveDownloads: Bool { downloads.contains { !$0.isActive } }

    private func enqueue(username: String, remotePath: String, size: UInt64) {
        guard !downloads.contains(where: {
            $0.username == username && $0.remotePath == remotePath && $0.isActive
        }) else { return }

        let destination = Self.localDestination(
            for: remotePath, downloadsFolder: URL(fileURLWithPath: downloadFolderPath))
        let request = SlskDownloadRequest(
            id: UUID(),
            username: username,
            remotePath: remotePath,
            size: size,
            partURL: destination.appendingPathExtension("part"),
            destinationURL: destination
        )
        downloads.append(SoulseekDownload(
            id: request.id, username: username, remotePath: remotePath,
            size: size, partURL: request.partURL, localURL: destination))

        Task {
            await waitForConnection()
            guard downloads.first(where: { $0.id == request.id })?.state != .cancelled else { return }
            guard let client, case .connected = state else {
                if let index = downloads.firstIndex(where: { $0.id == request.id }) {
                    downloads[index].state = .failed("Not connected")
                }
                return
            }
            await client.download(request)
        }
    }

    /// Local destination for a remote file: the download folder, plus the file's remote parent
    /// folder (so albums stay together), plus the file name.
    nonisolated static func localDestination(for remotePath: String, downloadsFolder: URL) -> URL {
        let components = remotePath.split(separator: "\\")
        let fileName = sanitize(String(components.last ?? "download"))
        var folder = downloadsFolder
        if let parent = components.dropLast().last.map({ sanitize(String($0)) }), !parent.isEmpty {
            folder = folder.appendingPathComponent(parent)
        }
        return folder.appendingPathComponent(fileName)
    }

    /// Remote names come from other people's file systems; keep them safe as macOS file names.
    nonisolated static func sanitize(_ name: String) -> String {
        var cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.isEmpty ? "download" : cleaned
    }

    /// Imports finished downloads' folders after a short settle, so an album lands as one scan.
    /// Retries while the library is busy with another scan.
    private func scheduleImport(of folder: URL) {
        pendingImportFolders.insert(folder)
        importTask?.cancel()
        importTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, importFolders != nil else { return }
            for _ in 0 ..< 60 {
                let folders = Array(pendingImportFolders)
                guard !folders.isEmpty else { return }
                if importFolders?(folders) == true {
                    pendingImportFolders.subtract(folders)
                    notifyFinishedFolders(folders)
                    return
                }
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return }
            }
        }
    }

    /// One notification per downloaded folder once nothing in it is still transferring.
    private func notifyFinishedFolders(_ folders: [URL]) {
        guard postsNotifications else { return }
        for folder in folders {
            let inFolder = downloads.filter { $0.localURL.deletingLastPathComponent() == folder }
            guard !inFolder.contains(where: \.isActive) else { continue }
            let done = inFolder.filter { if case .finished = $0.state { true } else { false } }.count
            guard done > 0 else { continue }
            Notifier.post(
                title: "Downloaded “\(folder.lastPathComponent)”",
                body: "\(done) \(done == 1 ? "file" : "files") added to the library.")
        }
    }

    var statusText: String {
        switch state {
        case .disconnected: "Not connected"
        case .connecting: "Connecting…"
        case .connected(let user): "Connected as \(user)"
        case .failed(let reason): reason
        }
    }
}

// MARK: Keychain

/// Minimal generic-password storage so the Soulseek password never sits in plain text.
enum Keychain {
    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func string(service: String, account: String) -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, service: String, account: String) {
        let query = baseQuery(service: service, account: account)
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
    }

    static func delete(service: String, account: String) {
        SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    }
}
