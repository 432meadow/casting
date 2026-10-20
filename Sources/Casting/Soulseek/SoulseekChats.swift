import Foundation
import Observation

/// One line in a private conversation.
struct SoulseekChatMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var text: String
    var isOutgoing: Bool
    /// Waited on the server while we were offline, and arrived at login.
    var wasOffline = false
    /// Couldn't be handed to the server (not connected).
    var failed = false
}

/// Everything said between us and one user.
struct SoulseekConversation: Codable, Identifiable, Equatable {
    var user: String
    var messages: [SoulseekChatMessage] = []
    var unread = 0
    /// When the conversation was opened, so a new empty one sorts to the top.
    var started = Date()

    var id: String { user }
    var lastDate: Date { messages.last?.date ?? started }
}

/// Private conversations, latest first, kept in one JSON file in the app's support folder.
@MainActor
@Observable
final class SoulseekChats {
    private(set) var conversations: [SoulseekConversation] = []

    @ObservationIgnored private let fileURL: URL?
    private static let maxMessagesPerConversation = 2000
    nonisolated private static let writeQueue = DispatchQueue(label: "casting.soulseek.chats", qos: .utility)

    nonisolated static var defaultURL: URL {
        LibraryStore.supportDirectory.appendingPathComponent("casting/Soulseek/Messages.json")
    }

    /// `fileURL` nil keeps history in memory only.
    init(fileURL: URL? = SoulseekChats.defaultURL) {
        self.fileURL = fileURL
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let saved = try? decoder.decode([SoulseekConversation].self, from: data) {
            conversations = saved.sorted { $0.lastDate > $1.lastDate }
        }
    }

    var unreadTotal: Int { conversations.reduce(0) { $0 + $1.unread } }

    func conversation(with user: String) -> SoulseekConversation? {
        conversations.first { $0.user == user }
    }

    /// Makes sure a conversation with `user` exists (for "Message user").
    func open(_ user: String) {
        guard conversation(with: user) == nil else { return }
        conversations.insert(SoulseekConversation(user: user), at: 0)
        save()
    }

    /// Files an incoming message; `unread` false when the user is looking at the conversation.
    func receive(_ message: SlskPrivateMessage, unread: Bool) {
        append(SoulseekChatMessage(
            date: message.timestamp, text: message.message, isOutgoing: false, wasOffline: !message.isNew),
               to: message.username, unread: unread)
    }

    /// Files one of our messages; returns its ID so a failed send can be marked.
    @discardableResult
    func addOutgoing(_ text: String, to user: String) -> UUID {
        let message = SoulseekChatMessage(date: Date(), text: text, isOutgoing: true)
        append(message, to: user, unread: false)
        return message.id
    }

    func markFailed(_ id: UUID, in user: String) {
        guard let index = conversations.firstIndex(where: { $0.user == user }),
              let messageIndex = conversations[index].messages.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].messages[messageIndex].failed = true
        save()
    }

    func markRead(_ user: String) {
        guard let index = conversations.firstIndex(where: { $0.user == user }),
              conversations[index].unread > 0 else { return }
        conversations[index].unread = 0
        save()
    }

    func remove(_ user: String) {
        conversations.removeAll { $0.user == user }
        save()
    }

    private func append(_ message: SoulseekChatMessage, to user: String, unread: Bool) {
        var conversation = conversations.first { $0.user == user } ?? SoulseekConversation(user: user)
        conversations.removeAll { $0.user == user }
        // Offline messages carry the time the server got them; keep the thread in order.
        if let last = conversation.messages.last, last.date > message.date {
            let index = conversation.messages.lastIndex { $0.date <= message.date }.map { $0 + 1 } ?? 0
            conversation.messages.insert(message, at: index)
        } else {
            conversation.messages.append(message)
        }
        if conversation.messages.count > Self.maxMessagesPerConversation {
            conversation.messages.removeFirst(conversation.messages.count - Self.maxMessagesPerConversation)
        }
        if unread { conversation.unread += 1 }
        let position = conversations.firstIndex { $0.lastDate <= conversation.lastDate } ?? conversations.count
        conversations.insert(conversation, at: position)
        save()
    }

    /// Writes the whole history off the main thread, in order.
    private func save() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(conversations) else { return }
        Self.writeQueue.async {
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Waits for pending writes (tests read the file straight back).
    nonisolated static func flushWrites() {
        writeQueue.sync {}
    }
}
