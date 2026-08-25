import Foundation

struct Tag: Identifiable, Codable, Equatable {
    let id: Int
    var name: String
    var color: String?
}
