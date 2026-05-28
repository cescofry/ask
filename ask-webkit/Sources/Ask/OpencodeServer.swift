import Foundation

// ---------------------------------------------------------------------------
// Opencode server lifecycle management
// ---------------------------------------------------------------------------

class OpencodeServer {
    private var process: Process?
    private var ownsProcess = false

    /// The base URL where the opencode web UI is served.
    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    /// The URL that opens the web UI focused on the configured project with a new session.
    /// The opencode web SPA uses URL-safe base64 encoding of the directory path as the route slug.
    var projectURL: URL {
        let encoded = Data(workingDir.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(string: "http://127.0.0.1:\(port)/\(encoded)/session")!
    }

    private let model: String
    private let workingDir: String
    private let port: Int
    /// The configured password (empty string means no auth).
    let password: String

    init(config: AppConfig) {
        self.model = config.model
        self.workingDir = config.web.workingDir
        self.port = config.web.port
        self.password = config.web.password
    }

    // MARK: - Health check

    /// Returns `true` if the server is responding on the configured port.
    func isRunning() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var reachable = false

        var request = URLRequest(url: baseURL)
        request.timeoutInterval = 1.0
        request.httpMethod = "HEAD"

        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, (200..<500).contains(http.statusCode) {
                reachable = true
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 2.0)
        return reachable
    }

    // MARK: - Start / stop

    /// Ensure the opencode server is running.
    /// If already running on the configured port, reuse it.
    /// Otherwise, start a new process.
    func ensureRunning(completion: @escaping (Bool) -> Void) {
        if isRunning() {
            completion(true)
            return
        }

        startProcess(completion: completion)
    }

    private func startProcess(completion: @escaping (Bool) -> Void) {
        // Resolve opencode path
        let opencodePath = resolveOpencodePath()

        // Ensure a project-local opencode.json exists in the working directory
        // so the server picks up the configured model.
        // The `serve` subcommand does not accept --model directly.
        ensureOpencodeConfig()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: opencodePath)

        var args: [String] = []
        if opencodePath == "/usr/bin/env" {
            args.append("opencode")
        }
        args += [
            "serve",
            "--hostname", "127.0.0.1",
            "--port", String(port),
        ]
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: workingDir)

        // Pass password as environment variable for opencode web auth
        var env = ProcessInfo.processInfo.environment
        if !password.isEmpty {
            env["OPENCODE_SERVER_PASSWORD"] = password
        } else {
            env.removeValue(forKey: "OPENCODE_SERVER_PASSWORD")
        }
        proc.environment = env

        // Suppress server output
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            NSLog("Ask: failed to start opencode: \(error)")
            completion(false)
            return
        }

        self.process = proc
        self.ownsProcess = true

        // Poll until the server is up (max ~10 seconds)
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            var attempts = 0
            while attempts < 50 {
                Thread.sleep(forTimeInterval: 0.2)
                if self.isRunning() {
                    DispatchQueue.main.async { completion(true) }
                    return
                }
                attempts += 1
            }
            NSLog("Ask: opencode server did not start within 10 seconds")
            DispatchQueue.main.async { completion(false) }
        }
    }

    /// Terminate the server if we started it.
    func shutdown() {
        guard ownsProcess, let proc = process, proc.isRunning else { return }
        proc.terminate()
        proc.waitUntilExit()
        process = nil
        ownsProcess = false
    }

    // MARK: - Path resolution

    private func resolveOpencodePath() -> String {
        // Check common locations
        let candidates = [
            NSHomeDirectory() + "/.opencode/bin/opencode",
            "/usr/local/bin/opencode",
            "/opt/homebrew/bin/opencode",
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Fall back to PATH lookup via /usr/bin/env
        return "/usr/bin/env"
    }

    // MARK: - Project config

    /// Ensure opencode.json exists in the working directory with the configured model.
    /// If the file already exists, update the model field only.
    private func ensureOpencodeConfig() {
        let configURL = URL(fileURLWithPath: workingDir).appendingPathComponent("opencode.json")
        let fm = FileManager.default

        if fm.fileExists(atPath: configURL.path) {
            // Read existing config and update model if different
            if let data = try? Data(contentsOf: configURL),
               var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                if json["model"] as? String != model {
                    json["model"] = model
                    if let updated = try? JSONSerialization.data(
                        withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
                    {
                        try? updated.write(to: configURL)
                    }
                }
            }
        } else {
            // Create minimal opencode.json
            let config: [String: Any] = ["model": model]
            if let data = try? JSONSerialization.data(
                withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            {
                try? data.write(to: configURL)
            }
        }
    }

}
