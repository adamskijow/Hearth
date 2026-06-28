// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import SupervisorCore

struct ConfigLoadingTests {
    private let path = "/Users/x/Library/Application Support/Hearth/config.json"

    @Test func firstRunSeedsTheDetectedBinary() {
        let r = ConfigLoading.resolve(fileContents: nil, configPath: path, detectedBinary: "/opt/homebrew/bin/ollama")
        #expect(r.createdDefault)
        #expect(!r.isProblem)
        #expect(r.config.ollamaBinaryPath == "/opt/homebrew/bin/ollama")
        #expect(r.note?.contains(path) == true)
    }

    @Test func firstRunWithoutDetectionFallsBackToTheDefaultPath() {
        let r = ConfigLoading.resolve(fileContents: nil, configPath: path, detectedBinary: nil)
        #expect(r.createdDefault)
        #expect(r.config.ollamaBinaryPath == HearthConfig.defaultOllamaBinaryPath)
    }

    @Test func cleanLoadParsesAndIsNeitherTemplateNorProblem() {
        let json = Data(#"{"port":12345,"runner":"mlx"}"#.utf8)
        let r = ConfigLoading.resolve(fileContents: json, configPath: path, detectedBinary: nil)
        #expect(!r.createdDefault)
        #expect(!r.isProblem)
        #expect(r.note == nil)
        #expect(r.config.port == 12345)
        #expect(r.config.runner == "mlx")
    }

    @Test func malformedFileIsAProblemAndNotOverwritten() {
        let bad = Data("{ this is not json".utf8)
        let r = ConfigLoading.resolve(fileContents: bad, configPath: path, detectedBinary: nil)
        #expect(r.isProblem)
        #expect(!r.createdDefault)  // must not be treated as first run and clobbered
        #expect(r.note != nil)
    }

    @Test func anEmptyButPresentFileIsAProblem() {
        // The app passes empty Data for a present-but-unreadable file; it must not
        // be mistaken for first run.
        let r = ConfigLoading.resolve(fileContents: Data(), configPath: path, detectedBinary: "/x/ollama")
        #expect(r.isProblem)
        #expect(!r.createdDefault)
    }
}
