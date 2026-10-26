import Darwin
import Foundation
import LumenCore

/// Owns a local llama-server while Muse Glimmer is in use.
public actor GlimmerServer {
    public let port: Int
    private let modelDirectory: URL?
    private var process: Process?
    private var loading: Task<URL, any Error>?
    private var launchID: UUID?
    private var ready = false

    public init(port: Int = 8786, modelDirectory: URL? = nil) {
        self.port = port
        self.modelDirectory = modelDirectory
    }

    /// Checks that the local executable and both model files can be used, without launching anything.
    public nonisolated static func checkInstallation(port: Int = 8786, modelDirectory: URL? = nil) throws {
        _ = try GlimmerLaunch.resolve(port: port, modelDirectory: modelDirectory)
    }

    deinit {
        loading?.cancel()
        if let process, process.isRunning { process.terminate() }
    }

    /// Starts the model and returns its chat base URL once health reports ready.
    public func start(progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> URL {
        guard !Task.isCancelled else { throw LumenError.cancelled }
        if ready, process?.isRunning == true { return baseURL }
        let task: Task<URL, any Error>
        if let loading {
            task = loading
        } else {
            let launch = try GlimmerLaunch.resolve(port: port, modelDirectory: modelDirectory)
            let child = Process()
            child.executableURL = launch.executable
            child.arguments = launch.arguments
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = FileHandle.standardError
            do { try child.run() }
            catch {
                throw LumenError.invalidResponse("Could not start llama-server: \(error.localizedDescription). Run brew install llama.cpp.")
            }
            let id = UUID()
            process = child
            launchID = id
            ready = false
            task = Task { try await self.waitForHealth(id: id, progress: progress) }
            loading = task
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Stops loading or serving and waits for the child to exit.
    public func stop() async {
        loading?.cancel()
        loading = nil
        ready = false
        launchID = nil
        guard let child = process else { return }
        process = nil
        if child.isRunning {
            child.terminate()
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while child.isRunning, ContinuousClock.now < deadline, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
        await Task.detached { child.waitUntilExit() }.value
    }

    private var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/v1")! }

    private func waitForHealth(id: UUID, progress: @Sendable (String) -> Void) async throws -> URL {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(180))
        progress("Loading Muse Glimmer…")
        do {
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                guard launchID == id else { throw LumenError.cancelled }
                guard process?.isRunning == true else {
                    throw LumenError.invalidResponse("llama-server exited while loading Muse Glimmer. Check its stderr output and the model files from scripts/get-glimmer.sh.")
                }
                let request = URLRequest(url: baseURL.deletingLastPathComponent().appendingPathComponent("health"), timeoutInterval: 2)
                let response = try? await session.data(for: request).1 as? HTTPURLResponse
                try Task.checkCancellation()
                guard launchID == id else { throw LumenError.cancelled }
                guard ContinuousClock.now < deadline else { throw LumenError.timedOut }
                if response?.statusCode == 200, process?.isRunning == true {
                    ready = true
                    loading = nil
                    return baseURL
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            throw LumenError.timedOut
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            if launchID == id { await stop() }
            if cancelled { throw LumenError.cancelled }
            throw error
        }
    }
}

/// Resolves the executable, model files and arguments without starting a process.
struct GlimmerLaunch: Sendable {
    static let modelName = "Muse-Glimmer-30B-KQuant-17GB-Q4_K_M.gguf"
    static let projectorName = "mmproj-Muse-Glimmer-30B-Q4_K_M.gguf"

    var executable: URL
    var arguments: [String]

    static func modelsDirectory(environment: [String: String], home: URL) -> URL {
        if let path = environment["LUMEN_GLIMMER_DIR"], !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if path == "~" { return home }
            if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2)), isDirectory: true) }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return home.appendingPathComponent("Library/Application Support/Lumen/Models/muse-glimmer", isDirectory: true)
    }

    static func resolve(port: Int, modelDirectory: URL? = nil,
                        environment: [String: String] = ProcessInfo.processInfo.environment,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                        isReadable: (String) -> Bool = {
                            var directory: ObjCBool = false
                            return FileManager.default.fileExists(atPath: $0, isDirectory: &directory)
                                && !directory.boolValue && FileManager.default.isReadableFile(atPath: $0)
                        }) throws -> GlimmerLaunch {
        guard (1...65535).contains(port) else { throw LumenError.invalidResponse("The Muse Glimmer port must be between 1 and 65535.") }
        var candidates = (environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: true).map {
            URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("llama-server")
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/llama-server"))
        guard let executable = candidates.first(where: { isExecutable($0.path) }) else {
            throw LumenError.invalidResponse("llama-server was not found. Run brew install llama.cpp, then try again.")
        }
        let directory = modelDirectory ?? modelsDirectory(environment: environment, home: home)
        let model = directory.appendingPathComponent(modelName)
        let projector = directory.appendingPathComponent(projectorName)
        for file in [model, projector] where !isReadable(file.path) {
            throw LumenError.invalidResponse("Missing or unreadable \(file.path). Run scripts/get-glimmer.sh, or set LUMEN_GLIMMER_DIR to the directory containing both model files.")
        }
        return GlimmerLaunch(executable: executable, arguments: [
            "-m", model.path, "--mmproj", projector.path, "--host", "127.0.0.1", "--port", String(port),
            "-c", "16384", "-ngl", "99", "--jinja",
        ])
    }
}
