import Foundation

enum AppPaths {
    static let appSupportDirName = "MLXLab"

    /// `~/Library/Application Support/MLXLab`
    static var appSupport: URL {
        let base = try! FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let dir = base.appendingPathComponent(appSupportDirName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `~/Library/Application Support/MLXLab/models`
    static var modelsDir: URL {
        let dir = appSupport.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `~/Library/Application Support/MLXLab/venv`
    static var venvDir: URL {
        appSupport.appendingPathComponent("venv", isDirectory: true)
    }

    /// Resolved path of the venv's python3.
    static var venvPython: URL {
        venvDir.appendingPathComponent("bin/python3")
    }

    /// Folder containing python_backend/*.py, copied into the bundle.
    static var bundledBackendDir: URL {
        Bundle.main.resourceURL!.appendingPathComponent("python_backend", isDirectory: true)
    }

    /// `~/Library/Application Support/MLXLab/logs/bridge.log`
    static var bridgeLog: URL {
        let dir = appSupport.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("bridge.log")
    }
}
