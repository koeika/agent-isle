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
        try markAll([key: completion])
    }
    func markAll(_ completions: [String: Double]) throws {
        var updated = marks
        for (key, completion) in completions where completion.isFinite && completion >= 0 {
            updated[key] = max(updated[key] ?? 0, completion)
        }
        guard updated != marks else { return }
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
