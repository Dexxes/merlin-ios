import Foundation

struct Highlight: Codable, Identifiable {
    let id: Int
    let articleId: Int
    let highlightedText: String
    let startXpath: String
    let startOffset: Int
    let endXpath: String
    let endOffset: Int
    let color: String
    let createdAt: String
}

struct HighlightCreate: Codable {
    let highlightedText: String
    let startXpath: String
    let startOffset: Int
    let endXpath: String
    let endOffset: Int
    let color: String
}
