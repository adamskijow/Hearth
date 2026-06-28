// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import SupervisorCore

/// Exit classification is a pure function over exit status plus captured stderr.
/// These drive it from fixture log lines, no real process involved.
struct ExitClassifierTests {
    private let runner = OllamaRunner(binaryPath: "/opt/homebrew/bin/ollama")

    @Test func runningWhenNoExit() {
        #expect(runner.classifyExit(nil, stderr: []) == .running)
    }

    @Test func cleanExit() {
        let exit = ProcessExit(code: 0)
        #expect(runner.classifyExit(exit, stderr: ["server shutting down"]) == .cleanExit)
    }

    @Test func plainCrashNonZero() {
        let exit = ProcessExit(code: 1)
        #expect(runner.classifyExit(exit, stderr: ["panic: nil map"]) == .crash(code: 1))
    }

    @Test func outOfMemoryFromMetalSignatureEvenWithCrashCode() {
        // A realistic unified memory blowout on Apple Silicon.
        let stderr = [
            "llama_model_load: loading model",
            "ggml_metal_graph_compute: command buffer 0 failed with status 5",
            "error: Insufficient Memory (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)"
        ]
        let exit = ProcessExit(code: 1)
        #expect(runner.classifyExit(exit, stderr: stderr) == .outOfMemory)
    }

    @Test func outOfMemoryTakesPrecedenceOverSignal() {
        // The OOM killer often delivers SIGKILL; the stderr signature should win.
        let exit = ProcessExit(code: 0, wasSignaled: true, signal: 9)
        #expect(runner.classifyExit(exit, stderr: ["fatal: out of memory"]) == .outOfMemory)
    }

    @Test func signalWithoutOOMSignature() {
        let exit = ProcessExit(code: 0, wasSignaled: true, signal: 9)
        #expect(runner.classifyExit(exit, stderr: ["received SIGKILL"]) == .signal(9))
    }

    @Test func matchingIsCaseInsensitive() {
        let exit = ProcessExit(code: 2)
        #expect(runner.classifyExit(exit, stderr: ["FATAL: OUT OF MEMORY"]) == .outOfMemory)
    }

    @Test func cannotAllocateIsOOM() {
        let exit = ProcessExit(code: 134)
        #expect(runner.classifyExit(exit, stderr: ["ggml: failed to allocate buffer"]) == .outOfMemory)
    }

    @Test func emptyStderrCrashStillClassifiesByCode() {
        let exit = ProcessExit(code: 2)
        #expect(runner.classifyExit(exit, stderr: []) == .crash(code: 2))
    }
}
