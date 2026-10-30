import Foundation
import LumenCore

/// Meta's published Standard pay-as-you-go prices in US dollars.
public enum MetaPricing {
    public static let date = "2026-10-26"
    public static let source = URL(string: "https://dev.meta.ai/docs/pricing-rate-limits")!

    public enum Price: Equatable, Sendable {
        case tokens(input: Double, cachedInput: Double, output: Double)
        case image(Double)
        case audio(perHour: Double)
    }

    /// Token prices are per million tokens; image prices are per returned or segmented image; audio is per hour heard.
    public static let prices: [String: Price] = [
        "muse-spark-1.3": .tokens(input: 1.25, cachedInput: 0.15, output: 4.25),
        "muse-wonder-1.0": .tokens(input: 4, cachedInput: 0.20, output: 20),
        "muse-image-1.0": .image(0.01),
        "sam-3.1": .image(2.50 / 1_000),
        "muse-voice-transcribe-1.0": .audio(perHour: 0.18),
    ]

    public static func cost(model: String, inputTokens: Int, cachedInputTokens: Int = 0, outputTokens: Int) -> Double? {
        guard case .tokens(let input, let cached, let output) = prices[model] else { return nil }
        let prompt = max(0, inputTokens)
        let cachedTokens = min(prompt, max(0, cachedInputTokens))
        return (Double(prompt - cachedTokens) * input + Double(cachedTokens) * cached
                + Double(max(0, outputTokens)) * output) / 1_000_000
    }

    public static func cost(model: String, images: Int) -> Double? {
        guard case .image(let price) = prices[model] else { return nil }
        return Double(max(0, images)) * price
    }

    /// Audio is billed by its whole seconds, rounded down.
    public static func cost(model: String, audioSeconds: Int) -> Double? {
        guard case .audio(let perHour) = prices[model] else { return nil }
        return Double(max(0, audioSeconds)) * perHour / 3_600
    }

    /// Two Spark calls, two SAM images and one redraw, without cached input.
    public static var defaultPhotoCost: Double { photoCost(includingPlanning: true) }

    public static func photoCost(includingPlanning: Bool) -> Double {
        let planning = includingPlanning
            ? 2 * cost(model: "muse-spark-1.3", inputTokens: 3_000, outputTokens: 1_000)! : 0
        return planning + cost(model: "sam-3.1", images: 2)! + cost(model: "muse-image-1.0", images: 1)!
    }
}

/// Token counts from chat completions, including reasoning within completion tokens.
struct MetaTokenUsage: Decodable {
    struct Details: Decodable { var cached_tokens: Int? }
    var prompt_tokens: Int
    var completion_tokens: Int
    var prompt_tokens_details: Details?

    func usage(model: String, recordsCost: Bool) -> ModelUsage {
        let cached = prompt_tokens_details?.cached_tokens ?? 0
        return ModelUsage(cost: recordsCost ? MetaPricing.cost(model: model, inputTokens: prompt_tokens,
                                                               cachedInputTokens: cached, outputTokens: completion_tokens) : nil,
                          inputTokens: prompt_tokens, cachedInputTokens: cached, outputTokens: completion_tokens)
    }
}
