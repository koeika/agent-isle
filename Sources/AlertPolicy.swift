import Foundation

enum AlertPolicy {
    static func priority(_ status: String) -> Int {
        switch status {
        case "waiting": return 3
        case "error": return 2
        default: return 1
        }
    }
    static func expires(_ status: String) -> Bool { status != "waiting" }
}
