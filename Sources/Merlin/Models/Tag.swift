import Foundation

struct Tag: Identifiable, Codable, Equatable {
    let id: Int
    var name: String
    var color: String?
    /// Eltern-Tag bei verschachtelten Tags; `nil` = oberste Ebene. Ältere
    /// Server liefern das Feld nicht, dann sind alle Tags oberste Ebene.
    var parentId: Int?
}
