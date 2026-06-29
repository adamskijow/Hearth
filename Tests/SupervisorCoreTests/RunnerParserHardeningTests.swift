// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import SupervisorCore

/// Adversarial input for every runner's model parser. A runner parses whatever an
/// HTTP server hands back, so malformed, truncated, or hostile bodies must fail
/// cleanly (throw) or return safely, never crash. These lock that in.
struct RunnerParserHardeningTests {
    private let ollama = OllamaRunner(binaryPath: "/usr/bin/true")
    private let lmStudio = LMStudioRunner(binaryPath: "/usr/bin/true")
    private let mlx = MLXRunner(binaryPath: "/usr/bin/true")

    private func data(_ string: String) -> Data { Data(string.utf8) }

    /// Bodies that are not the JSON shape each parser expects: every parser must
    /// throw rather than crash or return garbage.
    private let malformed: [String] = [
        "",                         // empty body
        "   ",                      // whitespace only
        "not json at all",          // not JSON
        "{",                        // truncated object
        "{\"models\":",            // truncated mid-value
        "[]",                       // array where an object is expected
        "null",                     // JSON null
        "42",                       // a bare number
        "\"a string\"",            // a bare string
        "{\"models\":\"nope\"}",  // wrong type for the list
        "{\"data\":{}}",          // wrong type (object, not array)
    ]

    @Test func everyParserThrowsOnMalformedBodies() {
        for body in malformed {
            #expect(throws: (any Error).self, "ollama should reject \(body.debugDescription)") {
                _ = try ollama.parseResidentModels(data(body))
            }
            #expect(throws: (any Error).self, "lmstudio should reject \(body.debugDescription)") {
                _ = try lmStudio.parseResidentModels(data(body))
            }
            #expect(throws: (any Error).self, "mlx should reject \(body.debugDescription)") {
                _ = try mlx.parseResidentModels(data(body))
            }
        }
    }

    @Test func emptyModelListsParseToNoModels() throws {
        #expect(try ollama.parseResidentModels(data(#"{"models":[]}"#)).isEmpty)
        #expect(try lmStudio.parseResidentModels(data(#"{"data":[]}"#)).isEmpty)
        #expect(try mlx.parseResidentModels(data(#"{"data":[]}"#)).isEmpty)
    }

    @Test func ollamaToleratesMissingPerModelFields() throws {
        // A model entry with no name and no model id falls back rather than crashing.
        let models = try ollama.parseResidentModels(data(#"{"models":[{}]}"#))
        #expect(models.count == 1)
        #expect(models.first?.name == "unknown")
        // model id is used when name is absent.
        let byModelID = try ollama.parseResidentModels(data(#"{"models":[{"model":"llama3:8b"}]}"#))
        #expect(byModelID.first?.name == "llama3:8b")
    }

    @Test func lmStudioRequiresAModelIDButToleratesMissingState() throws {
        // Missing id is a hard error (the model is unidentifiable).
        #expect(throws: (any Error).self) {
            _ = try lmStudio.parseResidentModels(data(#"{"data":[{"state":"loaded"}]}"#))
        }
        // Missing state simply means not loaded, so it is filtered out, not a crash.
        #expect(try lmStudio.parseResidentModels(data(#"{"data":[{"id":"m"}]}"#)).isEmpty)
        // A loaded model with an id comes through.
        let loaded = try lmStudio.parseResidentModels(data(#"{"data":[{"id":"m","state":"loaded"}]}"#))
        #expect(loaded.map(\.name) == ["m"])
    }

    @Test func wrongFieldTypesAreRejected() {
        // Numbers where strings belong must throw, not coerce.
        #expect(throws: (any Error).self) {
            _ = try ollama.parseResidentModels(data(#"{"models":[{"name":123}]}"#))
        }
        #expect(throws: (any Error).self) {
            _ = try mlx.parseResidentModels(data(#"{"data":[{"id":true}]}"#))
        }
    }

    @Test func aHugeModelListIsHandled() throws {
        // A pathologically long but valid list parses without blowing up.
        let entries = (0..<5000).map { #"{"id":"model-\#($0)"}"# }.joined(separator: ",")
        let models = try mlx.parseResidentModels(data("{\"data\":[\(entries)]}"))
        #expect(models.count == 5000)
    }
}
