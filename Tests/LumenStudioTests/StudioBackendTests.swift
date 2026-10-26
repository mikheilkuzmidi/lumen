import Foundation
import LumenCore
import LumenOpen
import Synchronization
import Testing
@testable import LumenStudio

@Suite("Studio backends")
@MainActor
struct StudioBackendTests {
    @Test(arguments: ["llama-server was not found. Run brew install llama.cpp.",
                      "Missing model file. Run scripts/get-glimmer.sh.",
                      "Missing vision projector. Run scripts/get-glimmer.sh."])
    func unavailableGlimmerExplainsWhatIsMissing(message: String) async {
        let server = StudioTestGlimmer()
        let backends = makeBackends(server: server, installationIssue: message)
        await backends.refreshAvailability()
        #expect(backends.availability(for: .meta).isEnabled)
        #expect(!backends.availability(for: .glimmer).isEnabled)
        #expect(backends.availability(for: .glimmer).help == message)
        #expect(!backends.availability(for: .sparkOpen).isEnabled)
        #expect(await server.starts == 0)
    }

    @Test func installedFilesAndBinaryEnableGlimmerWithoutStartingIt() async {
        let server = StudioTestGlimmer()
        let backends = makeBackends(server: server)
        await backends.refreshAvailability()
        #expect(backends.availability(for: .glimmer).isEnabled)
        #expect(await server.starts == 0)
    }

    @Test func answeringServerEnablesGlimmerWithoutInstallationAndIsNeverStopped() async throws {
        let server = StudioTestGlimmer()
        let backends = makeBackends(server: server, answers: true, installationIssue: "Run brew install llama.cpp.")
        await backends.refreshAvailability()
        #expect(backends.availability(for: .glimmer).isEnabled)
        backends.choose(.glimmer)
        let models = try await backends.models()
        #expect(models.planner.modelID == "muse-glimmer")
        backends.choose(.meta)
        await backends.shutdown()
        #expect(await server.starts == 0)
        #expect(await server.stops == 0)
    }

    @Test func providerNeedsBothSavedURLAndKeyAndAValidModel() async throws {
        for (url, key, model) in [("", "key", StudioProvider.defaultModel),
                                  ("https://provider.example/v1", "", StudioProvider.defaultModel),
                                  ("file:///tmp/provider", "key", StudioProvider.defaultModel),
                                  ("https://provider.example/v1", "key", " ")] {
            #expect(throws: (any Error).self) { try StudioProvider(baseURL: url, key: key, modelID: model) }
        }
        let provider = try provider()
        let backends = makeBackends(server: StudioTestGlimmer(), provider: provider)
        await backends.refreshAvailability()
        #expect(backends.availability(for: .sparkOpen).isEnabled)
        backends.choose(.sparkOpen)
        #expect(try await backends.models().planner.modelID == "deployed-spark-open")
        await backends.shutdown()
    }

    @Test func choosingGlimmerStartsOnceAndModelRequestsWaitForReadiness() async throws {
        let server = StudioTestGlimmer()
        var remembered: [StudioScript.Backend] = []
        let backends = makeBackends(server: server, remember: { remembered.append($0) })
        backends.choose(.glimmer)
        backends.choose(.glimmer)
        await server.waitUntilStarted()
        let first = await studioWaitingForModels(backends)
        let second = await studioWaitingForModels(backends)
        #expect(backends.isLoading)
        #expect(backends.status == "Loading Muse Glimmer on this Mac…")
        #expect(await server.starts == 1)
        await server.succeed()
        #expect(try await first.value.planner.modelID == "muse-glimmer")
        #expect(try await second.value.planner.modelID == "muse-glimmer")
        #expect(!backends.isLoading && backends.loadDuration != nil)
        #expect(backends.status?.contains("s to load") == true)
        backends.choose(.meta)
        await backends.shutdown()
        #expect(await server.stops == 1)
        #expect(remembered == [.glimmer, .glimmer, .meta])
    }

    @Test func loadFailureShowsItsOwnMessageAndRemembersMetaFallback() async throws {
        let server = StudioTestGlimmer()
        var remembered: [StudioScript.Backend] = []
        let backends = makeBackends(server: server, remember: { remembered.append($0) })
        backends.choose(.glimmer)
        await server.waitUntilStarted()
        let request = await studioWaitingForModels(backends)
        await server.fail("The vision projector could not be loaded.")
        await #expect(throws: (any Error).self) { try await request.value }
        #expect(backends.selection == .meta)
        #expect(backends.issue == "The vision projector could not be loaded.")
        #expect(remembered == [.glimmer, .meta])
        #expect(!backends.isLoading)
        await backends.shutdown()
        #expect(await server.stops == 1)
    }

    @Test func loadTimeComesFromTheElapsedStartupTime() async throws {
        let server = StudioTestGlimmer()
        let times = Mutex([Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 133)])
        var services = studioBackendServices(server: server)
        services.now = { times.withLock { $0.removeFirst() } }
        let backends = StudioBackends(selection: .meta, services: services, remember: { _ in })
        backends.choose(.glimmer)
        await server.waitUntilStarted()
        await server.succeed()
        _ = try await backends.models()
        #expect(backends.loadDuration == 33)
        #expect(backends.status == "Muse Glimmer is ready (33.0 s to load).")
        await backends.shutdown()
    }

    @Test func cancellingAnInstructionWhileLoadingDoesNotStopTheSelectedRuntime() async throws {
        let server = StudioTestGlimmer()
        let backends = makeBackends(server: server)
        backends.choose(.glimmer)
        await server.waitUntilStarted()
        let request = await studioWaitingForModels(backends)
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(backends.selection == .glimmer && backends.isLoading)
        #expect(await server.stops == 0)
        await server.succeed()
        _ = try await backends.models()
        await backends.shutdown()
        #expect(await server.stops == 1)
    }

    @Test func switchingAwayDuringLoadingStopsTheOwnedServerWithoutFallingBack() async throws {
        let server = StudioTestGlimmer()
        let backends = makeBackends(server: server, provider: try provider())
        backends.choose(.glimmer)
        await server.waitUntilStarted()
        backends.choose(.sparkOpen)
        await backends.shutdown()
        #expect(backends.selection == .sparkOpen)
        #expect(backends.issue == nil)
        #expect(await server.stops == 1)
    }

    @Test func scriptedLoadFailureDoesNotChangeTheRememberedChoice() async {
        let server = StudioTestGlimmer()
        var remembered: [StudioScript.Backend] = []
        let backends = makeBackends(server: server, remember: { remembered.append($0) })
        backends.choose(.glimmer, remembering: false)
        await server.waitUntilStarted()
        let request = await studioWaitingForModels(backends)
        await server.fail("The model file is damaged.")
        await #expect(throws: (any Error).self) { try await request.value }
        #expect(backends.selection == .meta)
        #expect(remembered.isEmpty)
        await backends.shutdown()
    }

    @Test func shutdownStopsTheWindowServerAndActivationCanLoadAgain() async throws {
        let server = StudioTestGlimmer()
        let backends = makeBackends(server: server)
        backends.choose(.glimmer)
        await server.waitUntilStarted()
        await server.succeed()
        _ = try await backends.models()
        await backends.shutdown()
        await backends.activate()
        await server.waitUntilStarted(count: 2)
        await server.succeed()
        _ = try await backends.models()
        await backends.shutdown()
        #expect(await server.starts == 2)
        #expect(await server.stops == 2)
    }

    @Test(arguments: StudioScript.Backend.allCases)
    func agentReceivesTheChosenPlannerAndAlwaysUsesMetaForPixels(backend: StudioScript.Backend) async throws {
        let backends = makeBackends(server: StudioTestGlimmer(), answers: true, provider: try provider())
        backends.choose(backend)
        let models = try await backends.models(allowKeychainInteraction: false)
        let agent = EditAgent(planner: models.planner, segmenter: models.segmenter, generator: models.generator,
                              host: StudioBackendPhoto())
        let expected: String = switch backend {
        case .meta: "muse-spark-1.3"
        case .glimmer: "muse-glimmer"
        case .sparkOpen: "deployed-spark-open"
        }
        #expect(await agent.planner.modelID == expected)
        #expect(await agent.segmenter.modelID == "sam-3.1")
        #expect(await agent.generator.modelID == "muse-image-1.0")
        if let planner = models.planner as? LocalGlimmerPlanner { #expect(planner.baseURL == studioGlimmerURL) }
        if let planner = models.planner as? HostedSparkOpenPlanner {
            #expect(planner.endpoint.absoluteString == "https://provider.example/v1")
            #expect(planner.apiKey == "provider-test-key")
        }
        await backends.shutdown()
    }

    @Test func glimmerURLUsesTheEnvironmentOrTheDefault() {
        #expect(StudioBackends.glimmerURL([:]).absoluteString == "http://127.0.0.1:8786/v1")
        #expect(StudioBackends.glimmerURL(["LUMEN_GLIMMER_URL": " http://localhost:9000/v1 "]).port == 9000)
    }

    @Test func modelLabelsPreserveTheMeasuredDuration() {
        let trace = TraceEvent(kind: .plan, model: "muse-glimmer", detail: "Plan", started: Date(), duration: 72.6)
        #expect(trace.studioModelName == "Muse Glimmer")
        #expect(trace.duration == 72.6)
    }

    private func provider() throws -> StudioProvider {
        try StudioProvider(baseURL: "https://provider.example/v1", key: "provider-test-key", modelID: "deployed-spark-open")
    }

    private func makeBackends(server: StudioTestGlimmer, answers: Bool = false, installationIssue: String? = nil,
                              provider: StudioProvider? = nil,
                              remember: @escaping (StudioScript.Backend) -> Void = { _ in }) -> StudioBackends {
        StudioBackends(selection: .meta, baseURL: studioGlimmerURL,
                       services: studioBackendServices(server: server, answers: answers,
                                                        installationIssue: installationIssue, provider: provider), remember: remember)
    }
}

let studioGlimmerURL = URL(string: "http://127.0.0.1:9000/v1")!

@MainActor
func studioWaitingForModels(_ backends: StudioBackends) async -> Task<StudioModels, any Error> {
    let entered = AsyncStream<Void>.makeStream()
    let request = Task {
        entered.continuation.yield(())
        entered.continuation.finish()
        return try await backends.models()
    }
    for await _ in entered.stream {}
    return request
}

func studioBackendServices(server: StudioTestGlimmer, answers: Bool = false, installationIssue: String? = nil,
                           provider: StudioProvider? = nil) -> StudioBackendServices {
    StudioBackendServices(answers: { _ in answers }, checkInstallation: { _ in
        if let installationIssue { throw StudioScriptError.message(installationIssue) }
    }, makeServer: { _ in server }, provider: {
        guard let provider else { throw StudioScriptError.message("Save a provider base URL and API key in Settings.") }
        return provider
    }, models: { backend, base, _ in
        try StudioModels.configured(backend: backend, metaKey: "meta-test-key", glimmerURL: base, provider: provider)
    })
}

actor StudioTestGlimmer: StudioGlimmerServing {
    private(set) var starts = 0
    private(set) var stops = 0
    private var ready: CheckedContinuation<URL, any Error>?
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func start() async throws -> URL {
        starts += 1
        return try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            let finished = waiters.filter { $0.0 <= starts }
            waiters.removeAll { $0.0 <= starts }
            for (_, waiter) in finished { waiter.resume() }
        }
    }

    func waitUntilStarted(count: Int = 1) async {
        if starts >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func succeed() {
        ready?.resume(returning: studioGlimmerURL)
        ready = nil
    }

    func fail(_ message: String) {
        ready?.resume(throwing: StudioScriptError.message(message))
        ready = nil
    }

    func stop() {
        stops += 1
        ready?.resume(throwing: CancellationError())
        ready = nil
    }
}

private actor StudioBackendPhoto: EditHost {
    let image = EncodedImage(data: Data(), format: .png, size: PixelSize(width: 1, height: 1))
    func size() -> PixelSize { image.size }
    func render(maxLongEdge: Int) throws -> EncodedImage { image }
    func render(region: NormalizedRect, maxLongEdge: Int) throws -> EncodedImage { image }
    func apply(_ layer: Layer, assets: AssetStore) {}
    func remove(_ layer: Layer.ID) {}
}
