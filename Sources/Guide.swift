import AppKit

final class GuideController {
    var process: Process?
    var url: URL?
    var starting = false
    var pending: [(Bool) -> Void] = []
    let resources: URL
    init(resources: URL) { self.resources = resources }
    func open(_ completion: @escaping (Bool) -> Void) {
        if let url = url, process?.isRunning == true { completion(NSWorkspace.shared.open(url)); return }
        pending.append(completion)
        guard !starting else { return }; starting = true
        let child = Process(), output = Pipe()
        PythonRuntime.configure(child, resources: resources)
        child.arguments = [resources.appendingPathComponent("agent_isle/guide.py").path, "--assets", resources.appendingPathComponent("Guide").path, "--version", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.6.1"]
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        do {
            try child.run(); process = child
            DispatchQueue.global(qos: .utility).async {
                let bytes = output.fileHandleForReading.availableData
                let record = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
                let target = (record?["url"] as? String).flatMap(URL.init(string:))
                DispatchQueue.main.async {
                    self.starting = false
                    if let target = target, target.host == "127.0.0.1", target.scheme == "http" { self.url = target }
                    let ok = self.url.map { NSWorkspace.shared.open($0) } ?? false
                    let callbacks = self.pending; self.pending = []
                    callbacks.forEach { $0(ok) }
                }
            }
            // Never leave the UI waiting forever if the interpreter cannot start.
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, weak child] in
                guard let self = self, self.starting, self.process === child else { return }
                self.starting = false; child?.terminate(); self.process = nil
                let callbacks = self.pending; self.pending = []; callbacks.forEach { $0(false) }
            }
        } catch {
            starting = false; process = nil
            let callbacks = pending; pending = []; callbacks.forEach { $0(false) }
        }
    }
    func stop() { if process?.isRunning == true { process?.terminate() }; process = nil; url = nil }
}
