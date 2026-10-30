import Foundation
import LumenCore
import LumenMeta
import LumenOpen
import Observation

extension StudioScript.Backend {
    var title: String {
        switch self {
        case .meta: "Muse Spark (Meta)"
        case .glimmer: "Muse Glimmer on this Mac"
        case .sparkOpen: "Muse Spark Open"
        }
    }
}

struct StudioBackendAvailability: Equatable {
    var isEnabled: Bool
    var help: String
}

/// The saved hosting provider, with its key read from the Keychain.
struct StudioProvider: Sendable {
    static let defaultModel = "meta-models/muse-spark-open-1026"
    let baseURL: URL
    let key: String
    let modelID: String

    init(baseURL: String, key: String?, modelID: String) throws {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !key.isEmpty else {
            throw StudioScriptError.message("Save a provider base URL and API key in Settings to use Muse Spark Open.")
        }
        guard let url = URL(string: base), ["http", "https"].contains(url.scheme?.lowercased()),
              url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw StudioScriptError.message("The provider base URL must use HTTP or HTTPS, including /v1 when required.")
        }
        guard !model.isEmpty else { throw StudioScriptError.message("Enter the provider's model ID in Settings.") }
        self.baseURL = url
        self.key = key
        self.modelID = model
    }

    @MainActor static func saved(allowInteraction: Bool) throws -> StudioProvider {
        try StudioProvider(baseURL: StudioPreferences.providerURL,
                           key: StudioKeychain.read(account: .provider, allowInteraction: allowInteraction),
                           modelID: StudioPreferences.providerModel)
    }
}

/// Settings that contain no secrets.
@MainActor
enum StudioPreferences {
    static var backend: StudioScript.Backend {
        get { UserDefaults.standard.string(forKey: "plannerBackend").flatMap(StudioScript.Backend.init(rawValue:)) ?? .meta }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "plannerBackend") }
    }
    static var providerURL: String {
        get { UserDefaults.standard.string(forKey: "sparkOpenBaseURL") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "sparkOpenBaseURL") }
    }
    static var providerModel: String {
        get { UserDefaults.standard.string(forKey: "sparkOpenModel") ?? StudioProvider.defaultModel }
        set { UserDefaults.standard.set(newValue, forKey: "sparkOpenModel") }
    }
}

protocol StudioGlimmerServing: Sendable {
    func start() async throws -> URL
    func stop() async
}

private struct StudioGlimmerServer: StudioGlimmerServing {
    let server: GlimmerServer
    func start() async throws -> URL { try await server.start() }
    func stop() async { await server.stop() }
}

/// The effects needed to choose and prepare a planner, replaceable in offline tests.
struct StudioBackendServices {
    var answers: @Sendable (URL) async -> Bool = { base in
        let request = URLRequest(url: base.deletingLastPathComponent().appendingPathComponent("health"), timeoutInterval: 2)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return String(decoding: data, as: UTF8.self).contains("ok")
    }
    var checkInstallation: @Sendable (Int) throws -> Void = { try GlimmerServer.checkInstallation(port: $0) }
    var makeServer: @Sendable (Int) -> any StudioGlimmerServing = { StudioGlimmerServer(server: GlimmerServer(port: $0)) }
    var provider: @MainActor () throws -> StudioProvider = { try .saved(allowInteraction: false) }
    var models: @MainActor (StudioScript.Backend, URL, Bool) throws -> StudioModels = { backend, base, interaction in
        try StudioModels.configured(backend: backend, metaKey: StudioKeychain.runtimeKey(allowInteraction: interaction),
                                    glimmerURL: base, provider: backend == .sparkOpen ? .saved(allowInteraction: interaction) : nil)
    }
    var now: @Sendable () -> Date = { Date() }
}

/// Remembers the planner and owns only the local server this window starts.
@MainActor @Observable
final class StudioBackends {
    private(set) var selection: StudioScript.Backend
    private(set) var glimmerAvailability = StudioBackendAvailability(isEnabled: false, help: "Checking the local runtime…")
    private(set) var providerAvailability = StudioBackendAvailability(isEnabled: false, help: "Save a provider base URL and API key in Settings.")
    private(set) var isLoading = false
    private(set) var loadDuration: TimeInterval?
    var issue: String?
    @ObservationIgnored private let services: StudioBackendServices
    @ObservationIgnored private let remember: (StudioScript.Backend) -> Void
    @ObservationIgnored private let baseURL: URL
    @ObservationIgnored private var loading: Task<URL, any Error>?
    @ObservationIgnored private var stopping: Task<Void, Never>?
    @ObservationIgnored private var ownedServer: (any StudioGlimmerServing)?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var active = false
    @ObservationIgnored private var remembersSelection = true
    @ObservationIgnored private var refreshVersion = 0

    init(selection: StudioScript.Backend = StudioPreferences.backend,
         baseURL: URL = StudioBackends.glimmerURL(), services: StudioBackendServices = StudioBackendServices(),
         remember: @escaping (StudioScript.Backend) -> Void = { StudioPreferences.backend = $0 }) {
        self.selection = selection
        self.baseURL = baseURL
        self.services = services
        self.remember = remember
    }

    deinit {
        loading?.cancel()
        if let ownedServer { Task { await ownedServer.stop() } }
    }

    static func glimmerURL(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        environment["LUMEN_GLIMMER_URL"].flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            ?? URL(string: "http://127.0.0.1:8786/v1")!
    }

    var status: String? {
        guard selection == .glimmer else { return nil }
        if isLoading { return "Loading Muse Glimmer on this Mac…" }
        return loadDuration.map { String(format: "Muse Glimmer is ready (%.1f s to load).", $0) }
    }

    func availability(for backend: StudioScript.Backend) -> StudioBackendAvailability {
        switch backend {
        case .meta: StudioBackendAvailability(isEnabled: true, help: "Muse Spark plans and checks through the Meta API.")
        case .glimmer: glimmerAvailability
        case .sparkOpen: providerAvailability
        }
    }

    func activate() async {
        guard !active else { return }
        active = true
        await refreshAvailability()
        guard active else { return }
        if selection == .glimmer { beginLoading() }
    }

    func refreshAvailability() async {
        refreshVersion += 1
        let version = refreshVersion
        do {
            _ = try services.provider()
            providerAvailability = StudioBackendAvailability(isEnabled: true, help: "Plans and checks on your saved hosting provider.")
        } catch {
            providerAvailability = StudioBackendAvailability(isEnabled: false, help: error.localizedDescription)
        }
        let answers = await services.answers(baseURL)
        guard version == refreshVersion else { return }
        do {
            if !answers { try services.checkInstallation(baseURL.port ?? 8786) }
            glimmerAvailability = StudioBackendAvailability(isEnabled: true,
                help: answers ? "Use the Muse Glimmer server already answering." : "Load Muse Glimmer on this Mac. Plans may take a minute or more.")
        } catch {
            glimmerAvailability = StudioBackendAvailability(isEnabled: false, help: error.localizedDescription)
        }
    }

    func choose(_ backend: StudioScript.Backend, remembering: Bool = true) {
        if backend != selection {
            stopLoading()
            selection = backend
            issue = nil
        }
        remembersSelection = remembering
        if remembering { remember(backend) }
        if backend == .glimmer { beginLoading() }
    }

    func models(allowKeychainInteraction: Bool = true) async throws -> StudioModels {
        let backend = selection
        var base = baseURL
        if backend == .glimmer {
            beginLoading()
            if let loading {
                let readiness = AsyncThrowingStream<URL, any Error> { continuation in
                    let waiter = Task {
                        do {
                            continuation.yield(try await loading.value)
                            continuation.finish()
                        } catch { continuation.finish(throwing: error) }
                    }
                    continuation.onTermination = { _ in waiter.cancel() }
                }
                for try await ready in readiness { base = ready }
            }
        }
        try Task.checkCancellation()
        guard backend == selection else { throw LumenError.cancelled }
        return try services.models(backend, base, allowKeychainInteraction)
    }

    func shutdown() async {
        active = false
        refreshVersion += 1
        stopLoading()
        await stopping?.value
    }

    private func beginLoading() {
        guard loading == nil else { return }
        let id = UUID()
        generation = id
        isLoading = true
        loadDuration = nil
        let previousStop = stopping
        loading = Task {
            await previousStop?.value
            do {
                try Task.checkCancellation()
                if await services.answers(baseURL) {
                    try Task.checkCancellation()
                    guard generation == id else { throw LumenError.cancelled }
                    isLoading = false
                    return baseURL
                }
                try Task.checkCancellation()
                try services.checkInstallation(baseURL.port ?? 8786)
                let server = services.makeServer(baseURL.port ?? 8786)
                ownedServer = server
                let started = services.now()
                let base = try await server.start()
                try Task.checkCancellation()
                guard generation == id else { throw LumenError.cancelled }
                loadDuration = max(0, services.now().timeIntervalSince(started))
                isLoading = false
                return base
            } catch {
                if generation == id {
                    stopLoading()
                    issue = error.localizedDescription
                    selection = .meta
                    if remembersSelection { remember(.meta) }
                }
                throw error
            }
        }
    }

    private func stopLoading() {
        generation = UUID()
        loading?.cancel()
        loading = nil
        isLoading = false
        loadDuration = nil
        if let server = ownedServer {
            ownedServer = nil
            let previousStop = stopping
            stopping = Task {
                await previousStop?.value
                await server.stop()
            }
        }
    }
}

extension StudioModels {
    static func configured(backend: StudioScript.Backend, metaKey: String, glimmerURL: URL,
                           provider: StudioProvider? = nil) throws -> StudioModels {
        guard !metaKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LumenError.missingKey }
        let configuration = MetaConfiguration(apiKey: metaKey)
        let planner: any Planner
        let reviewConfiguration: MetaConfiguration
        switch backend {
        case .meta:
            planner = MetaPlanner(configuration: configuration)
            reviewConfiguration = configuration
        case .glimmer:
            planner = LocalGlimmerPlanner(baseURL: glimmerURL)
            // Glimmer writes 7–10 tokens a second on a Mac: its review of 16 photos ran to 4,560 tokens and 485 s, and
            // a review takes up to 20.
            reviewConfiguration = MetaConfiguration(apiKey: "local-glimmer", baseURL: glimmerURL, planningModel: planner.modelID, timeout: 1200,
                                                    recordsCost: false)
        case .sparkOpen:
            guard let provider else { throw StudioScriptError.message("Save the Muse Spark Open provider in Settings.") }
            planner = HostedSparkOpenPlanner(endpoint: provider.baseURL, apiKey: provider.key, modelID: provider.modelID)
            reviewConfiguration = MetaConfiguration(apiKey: provider.key, baseURL: provider.baseURL, planningModel: provider.modelID, recordsCost: false)
        }
        return StudioModels(planner: planner, segmenter: MetaSegmenter(configuration: configuration),
                            generator: MetaGenerator(configuration: configuration),
                            reviewer: MetaBatchPlanner(configuration: reviewConfiguration,
                                transport: backend == .glimmer ? GlimmerChatTransport() : RetryingMetaTransport()))
    }
}

extension TraceEvent {
    var studioModelName: String? {
        switch model {
        case "muse-glimmer": "Muse Glimmer"
        case "muse-spark-1.3": "Muse Spark"
        case "meta-models/muse-spark-open-1026": "Muse Spark Open"
        default: model
        }
    }
}
