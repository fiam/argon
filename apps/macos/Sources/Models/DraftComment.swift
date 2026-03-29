import Foundation

struct DraftComment: Codable, Identifiable {
    let id: UUID
    let threadId: UUID?
    let anchor: CommentAnchor
    let body: String
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case threadId = "thread_id"
        case anchor, body
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct DraftReviewData: Codable {
    let sessionId: UUID
    let comments: [DraftComment]
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case comments
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
