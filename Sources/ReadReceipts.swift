import Foundation

final class ReadReceipts {
    let url: URL
    private(set) var marks: [String: Double]
    var onChange: (() -> Void)?
    init(url: URL) {
        self.url = url
        marks = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]
    }
    func isUnread(key: String, completion: Double, unread: Bool) -> Bool {
        unread && (marks[key] ?? -1) < completion
    }
    func mark(key: String, completion: Double) throws {
        guard completion.isFinite && completion >= 0 else { return }
        var updated = marks
        updated[key] = max(updated[key] ?? 0, completion)
        if updated.count > 1000 {
            updated = Dictionary(uniqueKeysWithValues: updated.sorted { $0.value > $1.value }.prefix(1000).map { ($0.key, $0.value) })
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(updated).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        marks = updated
        onChange?()
    }
}
