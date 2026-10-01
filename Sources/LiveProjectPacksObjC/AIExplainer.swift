import Foundation
import FoundationModels

// Bridges Apple's on-device Foundation Models framework (macOS 26+,
// Apple Silicon, requires Apple Intelligence enabled) into the
// Objective-C app. Runs entirely on-device — no API key, no network
// call, no data leaves the Mac. @objc so main.m can call it directly
// via the generated AIExplainer-Swift.h header.
@objc public class LPPAIExplainer: NSObject {

    @objc public static func isAvailable() -> Bool {
        if case .available = SystemLanguageModel.default.availability {
            return true
        }
        return false
    }

    @objc public static func unavailabilityReason() -> String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return ""
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings to use this."
        case .unavailable(.modelNotReady):
            return "The on-device model is still downloading — try again shortly."
        case .unavailable:
            return "The on-device model isn't available right now."
        }
    }

    @objc public static func explainAsset(
        title: String,
        kind: String,
        contentSample: String,
        completion: @escaping (String?, String?) -> Void
    ) {
        Task {
            guard isAvailable() else {
                let reason = unavailabilityReason()
                await MainActor.run { completion(nil, reason) }
                return
            }
            do {
                let session = LanguageModelSession(instructions: """
                    You explain a single saved file/link/note inside a project asset manager \
                    called Live Project Packs, for someone deciding whether they need it. \
                    Be concise: 2-4 plain-language sentences. Don't restate the filename or \
                    kind verbatim; focus on what the content actually is and why it might matter.
                    """)
                let prompt = """
                    Kind: \(kind)
                    Title: \(title)
                    Content sample:
                    \(contentSample.isEmpty ? "(no extractable text content — explain based on the title and kind alone)" : contentSample)
                    """
                let response = try await session.respond(to: prompt)
                let content = response.content
                await MainActor.run { completion(content, nil) }
            } catch {
                await MainActor.run { completion(nil, error.localizedDescription) }
            }
        }
    }

    @objc public static func suggestAssetName(
        title: String,
        kind: String,
        contentSample: String,
        completion: @escaping (String?, String?) -> Void
    ) {
        Task {
            guard isAvailable() else {
                let reason = unavailabilityReason()
                await MainActor.run { completion(nil, reason) }
                return
            }
            do {
                let session = LanguageModelSession(instructions: """
                    You rename one saved item inside Live Project Packs. \
                    Return only a short useful title, no quotes, no markdown, no extension unless it is essential. \
                    Make it specific enough to scan quickly. Use 3-7 words when possible.
                    """)
                let prompt = """
                    Current title: \(title)
                    Kind: \(kind)
                    Content sample:
                    \(contentSample.isEmpty ? "(no extracted text available)" : contentSample)
                    """
                let response = try await session.respond(to: prompt)
                let content = response.content
                await MainActor.run { completion(content, nil) }
            } catch {
                await MainActor.run { completion(nil, error.localizedDescription) }
            }
        }
    }
}
