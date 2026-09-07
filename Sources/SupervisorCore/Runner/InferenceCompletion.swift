// SPDX-License-Identifier: MIT

import Foundation

/// These small probes request one token and no streaming. HTTP success alone,
/// an error envelope, or an unfinished chunk does not establish inference.
/// The size guard bounds decoding work; transport has its own response limits.
enum InferenceCompletion {
    private static let maximumBytes = 64 * 1024

    static func ollama(_ data: Data) -> Bool {
        struct Completion: Decodable {
            var done: Bool
            var eval_count: Int
            var error: String?
        }
        guard data.count <= maximumBytes,
              let response = try? JSONDecoder().decode(Completion.self, from: data)
        else { return false }
        return response.error == nil && response.done && response.eval_count > 0
    }

    static func openAI(_ data: Data) -> Bool {
        struct Completion: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { var content: String?; var reasoning_content: String? }
                var finish_reason: String?
                var message: Message
            }
            struct Usage: Decodable { var completion_tokens: Int }
            var choices: [Choice]
            var usage: Usage?
            // Any error value, regardless of its schema, invalidates the body.
        }
        guard data.count <= maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["error"] == nil,
              let response = try? JSONDecoder().decode(Completion.self, from: data),
              let choice = response.choices.first,
              choice.finish_reason == "stop" || choice.finish_reason == "length"
        else { return false }
        let text = (choice.message.content ?? "") + (choice.message.reasoning_content ?? "")
        return !text.isEmpty || (response.usage?.completion_tokens ?? 0) > 0
    }
}
