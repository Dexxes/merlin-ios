import Foundation

struct Reminder: Identifiable, Codable {
    let id: UUID
    let articleId: Int
    let articleTitle: String
    var triggerAt: Date
    var status: Status
    let createdAt: Date

    enum Status: String, Codable {
        case pending
        case fired
        case cancelled
    }

    init(articleId: Int, articleTitle: String, triggerAt: Date) {
        self.id           = UUID()
        self.articleId    = articleId
        self.articleTitle = articleTitle
        self.triggerAt    = triggerAt
        self.status       = .pending
        self.createdAt    = Date()
    }
}
