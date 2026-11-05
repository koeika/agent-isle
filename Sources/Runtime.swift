import Foundation

/// Shared, relocatable Python runtime. No developer tools required on recipients' Macs.
enum PythonRuntime {
    static func configure(_ process: Process, resources: URL) {
        let home = resources.appendingPathComponent("Runtime/python")
        process.executableURL = home.appendingPathComponent("bin/python3")
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "PYTHONPATH")
        env.removeValue(forKey: "PYTHONSTARTUP")
        env.removeValue(forKey: "PYTHONINSPECT")
        env["PYTHONHOME"] = home.path
        env["PYTHONNOUSERSITE"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env
    }
}
