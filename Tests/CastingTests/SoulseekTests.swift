import Foundation
import Testing
@testable import Casting

@Suite struct SlskWireTests {
    @Test func integersAndStringsRoundTrip() throws {
        var writer = SlskWriter()
        writer.u8(7)
        writer.bool(true)
        writer.u32(0xDEAD_BEEF)
        writer.u64(5_000_000_000)
        writer.string("héllo wörld")

        var reader = SlskReader(writer.data)
        #expect(try reader.u8() == 7)
        #expect(try reader.bool() == true)
        #expect(try reader.u32() == 0xDEAD_BEEF)
        #expect(try reader.u64() == 5_000_000_000)
        #expect(try reader.string() == "héllo wörld")
        #expect(reader.isAtEnd)
    }

    @Test func readerThrowsOnTruncation() {
        var reader = SlskReader(Data([1, 0]))
        #expect(throws: SlskError.self) { try reader.u32() }
    }

    @Test func latin1StringsDecode() throws {
        // Old clients send latin-1; "café" in latin-1 is not valid UTF-8.
        var writer = SlskWriter()
        writer.bytes(Data([0x63, 0x61, 0x66, 0xE9]))
        var reader = SlskReader(writer.data)
        #expect(try reader.string() == "café")
    }

    @Test func soulseekNSOversizeFileSizesFallBackToLowWord() throws {
        var writer = SlskWriter()
        writer.u32(3_000_000_000)
        writer.u32(0xFFFF_FFFF)  // NS garbage high word
        var reader = SlskReader(writer.data)
        #expect(try reader.fileSize() == 3_000_000_000)
    }

    @Test func ipv4BytesAreReversed() throws {
        // 1.2.3.4 travels as the bytes 4 3 2 1 (little-endian u32 of the network-order value).
        var reader = SlskReader(Data([4, 3, 2, 1]))
        #expect(try reader.ipv4() == "1.2.3.4")
    }

    @Test func framesReassembleAcrossChunks() throws {
        var message = SlskWriter()
        message.u32(5)
        message.u32(26)
        message.u8(9)
        var second = SlskWriter()
        second.u32(4)
        second.u32(32)
        let stream = message.data + second.data

        var frames = SlskFrameBuffer()
        var collected: [Data] = []
        for byte in stream {
            frames.append(Data([byte]))
            while let frame = try frames.nextFrame() { collected.append(frame) }
        }
        #expect(collected.count == 2)
        #expect(collected[0] == Data([26, 0, 0, 0, 9]))
        #expect(collected[1] == Data([32, 0, 0, 0]))
    }

    @Test func oversizedFramesAreRejected() {
        var frames = SlskFrameBuffer()
        frames.append(Data([0xFF, 0xFF, 0xFF, 0x7F, 0, 0]))
        #expect(throws: SlskError.self) { try frames.nextFrame() }
    }

    @Test func zlibRoundTrips() throws {
        let original = Data("the quick brown fox jumps over the lazy dog, twice over. ".utf8) + Data(repeating: 0x41, count: 10_000)
        let compressed = try SlskZlib.deflate(original)
        #expect(compressed.prefix(2) == Data([0x78, 0x9C]), "zlib header")
        #expect(compressed.count < original.count)
        #expect(try SlskZlib.inflate(compressed) == original)
    }

    @Test func inflateRejectsGarbage() {
        #expect(throws: SlskError.self) { try SlskZlib.inflate(Data("not zlib at all".utf8)) }
    }
}

@Suite struct SlskMessageTests {
    @Test func loginMessageMatchesProtocolDoc() throws {
        // The hash fixture comes from SLSKPROTOCOL.md's login example:
        // MD5("usernamepassword") = d51c9a7e9353746a6020f9602d452929.
        let message = SlskServerMessage.login(username: "username", password: "password")

        var reader = SlskReader(message)
        let length = try reader.u32()
        #expect(Int(length) == message.count - 4)
        #expect(try reader.u32() == 1)
        #expect(try reader.string() == "username")
        #expect(try reader.string() == "password")
        #expect(try reader.u32() == 160)
        #expect(try reader.string() == "d51c9a7e9353746a6020f9602d452929")
        #expect(try reader.u32() == 2)
        #expect(reader.isAtEnd)
    }

    @Test func loginReplyParsesBothOutcomes() throws {
        var success = SlskWriter()
        success.bool(true)
        success.string("Welcome!")
        success.u32(0x0102_0304)  // IP 1.2.3.4 (bytes reversed on the wire)
        success.string("hash")
        success.bool(false)
        let ok = try SlskLoginReply(parsing: success.data)
        #expect(ok.success)
        #expect(ok.greeting == "Welcome!")
        #expect(ok.ownIP == "1.2.3.4")

        var failure = SlskWriter()
        failure.bool(false)
        failure.string("INVALIDPASS")
        let bad = try SlskLoginReply(parsing: failure.data)
        #expect(!bad.success)
        #expect(bad.greeting == "INVALIDPASS")
    }

    @Test func fileSearchDropsLoneDashesAndUsesToken() throws {
        let message = SlskServerMessage.fileSearch(token: 0xCAFE, query: "artist - album")
        var reader = SlskReader(message)
        _ = try reader.u32()
        #expect(try reader.u32() == 26)
        #expect(try reader.u32() == 0xCAFE)
        #expect(try reader.string() == "artist album")
    }

    @Test func connectToPeerParses() throws {
        var payload = SlskWriter()
        payload.string("someuser")
        payload.string("P")
        payload.u32(0x0102_0304)
        payload.u32(2235)
        payload.u32(987_654)
        payload.bool(true)
        payload.u32(0)
        payload.u32(0)

        let request = try SlskConnectToPeer(parsing: payload.data)
        #expect(request.username == "someuser")
        #expect(request.connectionType == "P")
        #expect(request.host == "1.2.3.4")
        #expect(request.port == 2235)
        #expect(request.token == 987_654)
    }

    @Test func connectToPeerRejectsBadPorts() {
        var payload = SlskWriter()
        payload.string("someuser")
        payload.string("P")
        payload.u32(0x0102_0304)
        payload.u32(0)
        payload.u32(1)
        #expect(throws: SlskError.self) { try SlskConnectToPeer(parsing: payload.data) }
    }

    @Test func peerInitMessagesRoundTrip() throws {
        let pierce = SlskPeerInit.pierceFirewall(token: 42)
        var frames = SlskFrameBuffer()
        frames.append(pierce)
        let pierceFrame = try #require(try frames.nextFrame())
        guard case .pierceFirewall(let token) = try SlskPeerInit.parse(pierceFrame) else {
            Issue.record("expected PierceFireWall")
            return
        }
        #expect(token == 42)

        frames.append(SlskPeerInit.peerInit(username: "me", connectionType: "P"))
        let initFrame = try #require(try frames.nextFrame())
        guard case .peerInit(let username, let type) = try SlskPeerInit.parse(initFrame) else {
            Issue.record("expected PeerInit")
            return
        }
        #expect(username == "me")
        #expect(type == "P")
    }

    @Test func searchResponseParses() throws {
        var body = SlskWriter()
        body.string("uploader")
        body.u32(777)
        body.u32(2)
        // A FLAC with depth/rate attributes.
        body.u8(1)
        body.string(#"@@share\Music\Artist\Album\01 Song.flac"#)
        body.u64(31_337_000)
        body.string("flac")
        body.u32(3)
        body.u32(1); body.u32(245)       // duration
        body.u32(4); body.u32(44_100)    // sample rate
        body.u32(5); body.u32(16)        // bit depth
        // An MP3 with bitrate + VBR.
        body.u8(1)
        body.string(#"@@share\Music\Artist\Album\02 Song.mp3"#)
        body.u64(9_000_000)
        body.string("mp3")
        body.u32(2)
        body.u32(0); body.u32(320)       // bitrate
        body.u32(2); body.u32(1)         // VBR
        body.bool(true)                  // slot free
        body.u32(1_500_000)              // avg speed
        body.u32(0)                      // queue length
        body.u32(0)                      // unknown
        body.u32(0)                      // no private results

        let payload = try SlskZlib.deflate(body.data)
        let response = try SlskSearchResponse(parsing: payload)

        #expect(response.username == "uploader")
        #expect(response.token == 777)
        #expect(response.results.count == 2)

        let flac = response.results[0]
        #expect(flac.fileName == "01 Song.flac")
        #expect(flac.folder == #"Artist\Album"#)
        #expect(flac.size == 31_337_000)
        #expect(flac.durationSeconds == 245)
        #expect(flac.sampleRate == 44_100)
        #expect(flac.bitDepth == 16)
        #expect(flac.slotFree)
        #expect(flac.averageSpeed == 1_500_000)

        let mp3 = response.results[1]
        #expect(mp3.bitrate == 320)
        #expect(mp3.isVBR)
        #expect(mp3.username == "uploader")
    }

    @Test func searchResponseSurvivesMissingTrailingFields() throws {
        // Old clients stop after the result list; results should still come through.
        var body = SlskWriter()
        body.string("oldclient")
        body.u32(5)
        body.u32(1)
        body.u8(1)
        body.string(#"a\b.mp3"#)
        body.u64(100)
        body.string("mp3")
        body.u32(0)

        let response = try SlskSearchResponse(parsing: try SlskZlib.deflate(body.data))
        #expect(response.results.count == 1)
        #expect(response.results[0].slotFree == false)
    }

    @Test func transferMessagesRoundTrip() throws {
        // QueueUpload (peer code 43): just the remote path.
        var frames = SlskFrameBuffer()
        frames.append(SlskPeerMessage.queueUpload(path: #"@@x\Album\01.flac"#))
        var reader = SlskReader(try #require(try frames.nextFrame()))
        #expect(try reader.u32() == 43)
        #expect(try reader.string() == #"@@x\Album\01.flac"#)
        #expect(reader.isAtEnd)

        // TransferResponse (peer code 41), upload form: no size, reason only when rejecting.
        frames.append(SlskPeerMessage.transferResponse(token: 99, allowed: true))
        reader = SlskReader(try #require(try frames.nextFrame()))
        #expect(try reader.u32() == 41)
        #expect(try reader.u32() == 99)
        #expect(try reader.bool() == true)
        #expect(reader.isAtEnd)

        frames.append(SlskPeerMessage.transferResponse(token: 99, allowed: false, reason: "Cancelled"))
        reader = SlskReader(try #require(try frames.nextFrame()))
        _ = try reader.u32()
        _ = try reader.u32()
        #expect(try reader.bool() == false)
        #expect(try reader.string() == "Cancelled")
    }

    @Test func transferRequestParses() throws {
        var payload = SlskWriter()
        payload.u32(1)  // direction: peer uploads to us
        payload.u32(31_338)
        payload.string(#"@@x\Album\01.flac"#)
        payload.u64(9_999_999)

        let request = try SlskTransferRequest(parsing: payload.data)
        #expect(request.direction == 1)
        #expect(request.token == 31_338)
        #expect(request.path == #"@@x\Album\01.flac"#)
        #expect(request.size == 9_999_999)
    }

    @Test func uploadRejectionsParse() throws {
        var denied = SlskWriter()
        denied.string(#"a\b.mp3"#)
        denied.string("Queued")
        let deniedMessage = try SlskUploadDenied(parsing: denied.data)
        #expect(deniedMessage.path == #"a\b.mp3"#)
        #expect(deniedMessage.reason == "Queued")

        var failed = SlskWriter()
        failed.string(#"a\b.mp3"#)
        #expect(try SlskUploadFailed(parsing: failed.data).path == #"a\b.mp3"#)

        var place = SlskWriter()
        place.string(#"a\b.mp3"#)
        place.u32(7)
        let placeMessage = try SlskPlaceInQueueResponse(parsing: place.data)
        #expect(placeMessage.place == 7)
    }

    @Test func peerAddressReplyParses() throws {
        var payload = SlskWriter()
        payload.string("someuser")
        payload.u32(0x0102_0304)  // 1.2.3.4
        payload.u32(2235)
        payload.u32(1)

        let reply = try SlskPeerAddressReply(parsing: payload.data)
        #expect(reply.username == "someuser")
        #expect(reply.host == "1.2.3.4")
        #expect(reply.port == 2235)
    }

    @Test func frameBufferDrainsRawRemainder() throws {
        // An F connection's init frame is length-prefixed; the bytes after it are raw.
        var frames = SlskFrameBuffer()
        frames.append(SlskPeerInit.peerInit(username: "me", connectionType: "F"))
        frames.append(Data([0xAA, 0xBB, 0xCC]))
        _ = try #require(try frames.nextFrame())
        #expect(frames.drainRemaining() == Data([0xAA, 0xBB, 0xCC]))
        #expect(frames.drainRemaining().isEmpty)
    }

    @Test func downloadDestinationsPreserveTheRemoteFolder() {
        let downloads = URL(fileURLWithPath: "/tmp/Soulseek")
        let destination = SoulseekModel.localDestination(
            for: #"@@abc\Music\Artist\Great Album\01 Song.flac"#, downloadsFolder: downloads)
        #expect(destination.path == "/tmp/Soulseek/Great Album/01 Song.flac")

        // Hostile remote names can't escape the folder or hide the file.
        #expect(SoulseekModel.sanitize("a/b:c") == "a-b-c")
        #expect(SoulseekModel.sanitize("...hidden") == "hidden")
        #expect(SoulseekModel.sanitize("") == "download")

        let flat = SoulseekModel.localDestination(for: "justafile.mp3", downloadsFolder: downloads)
        #expect(flat.path == "/tmp/Soulseek/justafile.mp3")
    }

    @Test func qualityDescriptionsRead() {
        var result = SlskSearchResult(
            id: 0, username: "u", path: #"x\y.flac"#, size: 1, bitrate: nil, isVBR: false,
            durationSeconds: nil, sampleRate: 44_100, bitDepth: 16, slotFree: true,
            averageSpeed: 0, queueLength: 0
        )
        #expect(result.qualityDescription == "FLAC 16/44.1")

        result.path = #"x\y.mp3"#
        result.sampleRate = nil
        result.bitDepth = nil
        result.bitrate = 245
        result.isVBR = true
        #expect(result.qualityDescription == "MP3 245 VBR")
        #expect(result.availability == 0)
    }
}

@Suite struct SlskMessagingCodecTests {
    @Test func messageUserAndAckMatchTheSpec() throws {
        var reader = SlskReader(SlskServerMessage.messageUser(username: "friend", message: "héllo"))
        _ = try reader.u32()
        #expect(try reader.u32() == 22)
        #expect(try reader.string() == "friend")
        #expect(try reader.string() == "héllo")
        #expect(reader.isAtEnd)

        reader = SlskReader(SlskServerMessage.messageAcked(id: 0xABCD))
        _ = try reader.u32()
        #expect(try reader.u32() == 23)
        #expect(try reader.u32() == 0xABCD)
        #expect(reader.isAtEnd)
    }

    @Test func userLookupsCarryJustTheUsername() throws {
        for (message, code) in [
            (SlskServerMessage.watchUser("someone"), UInt32(5)),
            (SlskServerMessage.unwatchUser("someone"), 6),
            (SlskServerMessage.getUserStatus("someone"), 7),
            (SlskServerMessage.getUserStats("someone"), 36),
        ] {
            var reader = SlskReader(message)
            #expect(Int(try reader.u32()) == message.count - 4)
            #expect(try reader.u32() == code)
            #expect(try reader.string() == "someone")
            #expect(reader.isAtEnd)
        }
    }

    @Test func receivedPrivateMessageParses() throws {
        var body = SlskWriter()
        body.u32(77)
        body.u32(1_600_000_000)
        body.string("friend")
        body.string("are you around?")
        body.bool(false)
        let message = try SlskPrivateMessage(parsing: body.data)
        #expect(message.id == 77)
        #expect(message.timestamp == Date(timeIntervalSince1970: 1_600_000_000))
        #expect(message.username == "friend")
        #expect(message.message == "are you around?")
        #expect(!message.isNew)
    }

    @Test func watchUserReplyParsesBothOutcomes() throws {
        var body = SlskWriter()
        body.string("someone")
        body.bool(true)
        body.u32(1)  // away
        for value: UInt32 in [1000, 5, 0, 300, 20] { body.u32(value) }
        body.string("DE")
        let reply = try SlskWatchUserReply(parsing: body.data)
        #expect(reply.exists)
        #expect(reply.status == .away)
        #expect(reply.stats == SlskUserStats(averageSpeed: 1000, uploadCount: 5, files: 300, folders: 20))

        var missing = SlskWriter()
        missing.string("nobody")
        missing.bool(false)
        let none = try SlskWatchUserReply(parsing: missing.data)
        #expect(!none.exists)
        #expect(none.status == .offline)
        #expect(none.stats == nil)
    }

    @Test func statusAndStatsRepliesParse() throws {
        var status = SlskWriter()
        status.string("someone")
        status.u32(2)
        status.bool(true)
        let statusReply = try SlskUserStatusReply(parsing: status.data)
        #expect(statusReply.status == .online)
        #expect(statusReply.privileged)

        var stats = SlskWriter()
        stats.string("someone")
        for value: UInt32 in [64_000, 9, 0, 10_000, 800] { stats.u32(value) }
        let statsReply = try SlskUserStatsReply(parsing: stats.data)
        #expect(statsReply.username == "someone")
        #expect(statsReply.stats == SlskUserStats(averageSpeed: 64_000, uploadCount: 9, files: 10_000, folders: 800))
    }

    @Test func userInfoRoundTripsWithAndWithoutAPicture() throws {
        for picture in [nil, Data([1, 2, 3, 4, 5])] as [Data?] {
            let message = SlskPeerMessage.userInfoResponse(
                description: "about me", picture: picture, uploadSlots: 2, queueLength: 4, slotFree: true)
            var reader = SlskReader(message)
            #expect(Int(try reader.u32()) == message.count - 4)
            #expect(try reader.u32() == 16)
            let info = try SlskUserInfo(parsing: Data(message.dropFirst(8)))
            #expect(info == SlskUserInfo(description: "about me", picture: picture, uploadSlots: 2, queueLength: 4, slotFree: true))
        }
        // SoulseekQt leaves out the trailing upload permission.
        var short = SlskWriter()
        short.string("qt user")
        short.bool(false)
        short.u32(1)
        short.u32(0)
        short.bool(false)
        #expect(try SlskUserInfo(parsing: short.data).description == "qt user")
    }

    @Test func userInfoRequestIsEmpty() throws {
        #expect(SlskPeerMessage.userInfoRequest() == Data([4, 0, 0, 0, 15, 0, 0, 0]))
    }
}

@MainActor
@Suite struct SoulseekChatsTests {
    private func message(_ id: UInt32, from user: String, _ text: String, at seconds: TimeInterval, isNew: Bool = true) -> SlskPrivateMessage {
        SlskPrivateMessage(id: id, timestamp: Date(timeIntervalSince1970: seconds), username: user, message: text, isNew: isNew)
    }

    @Test func conversationsSortLatestFirstAndCountUnread() {
        let chats = SoulseekChats(fileURL: nil)
        chats.receive(message(1, from: "a", "first", at: 100), unread: true)
        chats.receive(message(2, from: "b", "second", at: 200), unread: true)
        chats.receive(message(3, from: "a", "third", at: 300), unread: true)
        #expect(chats.conversations.map(\.user) == ["a", "b"])
        #expect(chats.conversation(with: "a")?.unread == 2)
        #expect(chats.unreadTotal == 3)

        chats.markRead("a")
        #expect(chats.unreadTotal == 1)
        chats.addOutgoing("reply", to: "b")
        #expect(chats.conversations.first?.user == "b")
        #expect(chats.conversation(with: "b")?.messages.last?.isOutgoing == true)
    }

    @Test func offlineMessagesSlotInByTimestamp() {
        let chats = SoulseekChats(fileURL: nil)
        chats.receive(message(1, from: "a", "later", at: 500), unread: false)
        chats.receive(message(2, from: "a", "earlier", at: 100, isNew: false), unread: true)
        let messages = chats.conversation(with: "a")?.messages ?? []
        #expect(messages.map(\.text) == ["earlier", "later"])
        #expect(messages.first?.wasOffline == true)
    }

    @Test func historyPersists() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("casting-chats-\(UUID().uuidString)/Messages.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let chats = SoulseekChats(fileURL: url)
        chats.receive(message(1, from: "friend", "hello", at: 1_000), unread: true)
        let sent = chats.addOutgoing("hi back", to: "friend")
        chats.markFailed(sent, in: "friend")
        chats.open("someone new")
        SoulseekChats.flushWrites()

        let reloaded = SoulseekChats(fileURL: url)
        #expect(Set(reloaded.conversations.map(\.user)) == ["friend", "someone new"])
        let friend = try #require(reloaded.conversation(with: "friend"))
        #expect(friend.messages.map(\.text) == ["hello", "hi back"])
        #expect(friend.messages.last?.failed == true)
        #expect(friend.unread == 1)

        reloaded.remove("friend")
        SoulseekChats.flushWrites()
        #expect(SoulseekChats(fileURL: url).conversation(with: "friend") == nil)
    }
}
