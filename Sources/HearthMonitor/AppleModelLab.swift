// SPDX-License-Identifier: MIT

import AppKit
import Combine
import Foundation
import HearthMonitorCore
import SwiftUI

enum AppleModelLabSampling: String, CaseIterable, Sendable, Equatable, Identifiable {
    case automatic
    case greedy
    case varied

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .greedy: return "Repeatable"
        case .varied: return "Varied"
        }
    }
}

struct AppleModelLabRequest: Sendable, Equatable {
    static let maximumInstructionCharacters = 2_000
    static let maximumPromptCharacters = 8_000
    static let responseTokenRange = 16...512

    var instructions: String
    var prompt: String
    var sampling: AppleModelLabSampling
    var temperature: Double
    var maximumResponseTokens: Int

    var validationMessage: String? {
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a prompt to run a private model test."
        }
        if instructions.count > Self.maximumInstructionCharacters {
            return "System instructions must be (Self.maximumInstructionCharacters) characters or fewer."
        }
        if prompt.count > Self.maximumPromptCharacters {
            return "The prompt must be (Self.maximumPromptCharacters) characters or fewer."
        }
        return nil
    }

    var normalized: Self {
        Self(
            instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines),
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            sampling: sampling,
            temperature: min(2, max(0, temperature.isFinite ? temperature : 1)),
            maximumResponseTokens: min(
                Self.responseTokenRange.upperBound,
                max(Self.responseTokenRange.lowerBound, maximumResponseTokens)))
    }
}

struct AppleModelLabMetrics: Sendable, Equatable {
    var timeToFirstOutputSeconds: TimeInterval?
    var totalSeconds: TimeInterval
    var responseTokens: Int?
}

enum AppleModelLabResult: Sendable, Equatable {
    case completed(text: String, metrics: AppleModelLabMetrics)
    case stopped
    case busy
    case unavailable(AppleModelUnavailableReason)
    case failed(String)
}

protocol AppleModelLabRunning: Sendable {
    func availability() async -> AppleModelAvailability
    func run(
        _ request: AppleModelLabRequest,
        onPartial: @escaping @Sendable (String, TimeInterval?) async -> Void
    ) async -> AppleModelLabResult
    func stop() async
}

@MainActor
final class AppleModelLabModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running
        case stopping
    }

    static let defaultPrompt = "Explain in one sentence what makes an AI service healthy."

    @Published var availability: AppleModelAvailability
    @Published var instructions = "You are a concise, helpful assistant."
    @Published var prompt = defaultPrompt
    @Published var sampling = AppleModelLabSampling.automatic
    @Published var temperature = 1.0
    @Published var maximumResponseTokens = 128
    @Published private(set) var output = ""
    @Published private(set) var metrics: AppleModelLabMetrics?
    @Published private(set) var phase = Phase.idle
    @Published private(set) var message: String?

    private let runner: any AppleModelLabRunning
    private let onActivityChanged: (Bool) -> Void
    private var activeRunID: UUID?
    private var runTask: Task<Void, Never>?

    init(
        runner: any AppleModelLabRunning,
        availability: AppleModelAvailability,
        onActivityChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.runner = runner
        self.availability = availability
        self.onActivityChanged = onActivityChanged
    }

    var request: AppleModelLabRequest {
        AppleModelLabRequest(
            instructions: instructions,
            prompt: prompt,
            sampling: sampling,
            temperature: temperature,
            maximumResponseTokens: maximumResponseTokens)
    }

    var canRun: Bool {
        phase == .idle && availability == .available && request.validationMessage == nil
    }

    func refreshAvailability() {
        Task { [weak self, runner] in
            let current = await runner.availability()
            guard let self else { return }
            self.availability = current
        }
    }

    func run() {
        guard canRun else {
            message = request.validationMessage ?? availabilityMessage
            return
        }
        let runID = UUID()
        let submitted = request.normalized
        activeRunID = runID
        output = ""
        metrics = nil
        message = nil
        phase = .running
        onActivityChanged(true)
        runTask = Task { [weak self, runner] in
            let result = await runner.run(submitted) { [weak self] partial, firstOutput in
                await MainActor.run {
                    guard let self, self.activeRunID == runID else { return }
                    self.output = partial
                    if let firstOutput {
                        self.metrics = AppleModelLabMetrics(
                            timeToFirstOutputSeconds: firstOutput,
                            totalSeconds: firstOutput,
                            responseTokens: nil)
                    }
                }
            }
            guard let self else { return }
            self.finish(result, runID: runID)
            self.onActivityChanged(false)
        }
    }

    func stop() {
        guard phase == .running else { return }
        phase = .stopping
        Task.detached(priority: .userInitiated) { [runner] in
            await runner.stop()
        }
    }

    func clearResult() {
        guard phase == .idle else { return }
        output = ""
        metrics = nil
        message = nil
    }

    func endSession() {
        activeRunID = nil
        runTask = nil
        output = ""
        metrics = nil
        message = nil
        instructions = "You are a concise, helpful assistant."
        prompt = Self.defaultPrompt
        sampling = .automatic
        temperature = 1
        maximumResponseTokens = 128
        if phase == .idle { return }
        phase = .stopping
        Task.detached(priority: .userInitiated) { [weak self, runner] in
            await runner.stop()
            await MainActor.run {
                guard let self, self.activeRunID == nil else { return }
                self.phase = .idle
            }
        }
    }

    private func finish(_ result: AppleModelLabResult, runID: UUID) {
        guard activeRunID == runID else { return }
        activeRunID = nil
        phase = .idle
        switch result {
        case .completed(let text, let completedMetrics):
            output = text
            metrics = completedMetrics
        case .stopped:
            message = "Generation stopped. Apple may finish releasing its model request before another can begin."
        case .busy:
            message = "Another Hearth Apple Intelligence request is still finishing. Try again in a moment."
        case .unavailable(let reason):
            availability = .unavailable(reason)
            message = availabilityMessage
        case .failed(let failure):
            message = failure
        }
    }

    var availabilityMessage: String {
        switch availability {
        case .available:
            return "Apple Intelligence is available."
        case .unavailable(.unsupportedOS):
            return "The private Model Lab requires macOS 26 or later."
        case .unavailable(.deviceNotEligible):
            return "This Mac is not eligible for Apple Intelligence. Local AI Runner monitoring still works."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings before using the Model Lab."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still preparing its model. Try again after it finishes."
        case .unavailable(.unsupportedLocale):
            return "Apple Intelligence does not support the current language or locale for this request."
        case .unavailable(.frameworkUnavailable):
            return "The Foundation Models framework is not available."
        }
    }
}

@MainActor
final class AppleModelLabController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: AppleModelLabModel

    init(
        runner: any AppleModelLabRunning,
        availability: AppleModelAvailability,
        onActivityChanged: @escaping (Bool) -> Void
    ) {
        model = AppleModelLabModel(
            runner: runner,
            availability: availability,
            onActivityChanged: onActivityChanged)
        super.init()
    }

    func show(availability: AppleModelAvailability) {
        model.availability = availability
        model.refreshAvailability()
        if window == nil {
            let view = AppleModelLabView(
                model: model,
                onCopy: { [weak self] in self?.copyResponse() },
                onDone: { [weak self] in self?.window?.close() })
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Private Apple Intelligence Model Lab"
            window.styleMask = [.titled, .closable, .resizable]
            window.minSize = NSSize(width: 620, height: 620)
            window.setContentSize(NSSize(width: 720, height: 780))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.endSession()
        MonitorWindowActivation.restoreAccessoryWhenAppropriate()
    }

    private func copyResponse() {
        guard !model.output.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.output, forType: .string)
    }
}

struct AppleModelLabView: View {
    @ObservedObject var model: AppleModelLabModel
    let onCopy: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    availabilityCard
                    promptCard
                    responseCard
                }
                .padding(22)
            }
            Divider()
            footer
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Private Model Lab", systemImage: "testtube.2")
                .font(.title2.weight(.semibold))
            Text("Try a real prompt with Apple's on-device model without changing Hearth's health state, incidents, or alerts.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var availabilityCard: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.availabilityMessage)
                    .font(.callout)
                Text("Prompts and responses stay in memory, are cleared when this window closes, and never enter Hearth history or alerts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: model.availability == .available
                  ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        }
        .foregroundStyle(model.availability == .available ? Color.green : Color.orange)
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((model.availability == .available ? Color.green : Color.orange).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private var promptCard: some View {
        GroupBox("Prompt") {
            VStack(alignment: .leading, spacing: 11) {
                fieldLabel("System instructions", count: model.instructions.count,
                           limit: AppleModelLabRequest.maximumInstructionCharacters)
                TextEditor(text: $model.instructions)
                    .font(.body)
                    .frame(minHeight: 54, maxHeight: 78)
                    .padding(5)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                    .accessibilityLabel("System instructions")

                fieldLabel("User prompt", count: model.prompt.count,
                           limit: AppleModelLabRequest.maximumPromptCharacters)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $model.prompt)
                        .font(.body)
                        .frame(minHeight: 100)
                        .padding(5)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                        .accessibilityLabel("User prompt")
                    if model.prompt.isEmpty {
                        Text("Ask the on-device model something…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 13)
                            .allowsHitTesting(false)
                    }
                }

                Picker("Sampling", selection: $model.sampling) {
                    ForEach(AppleModelLabSampling.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityHint("Automatic uses Apple's defaults. Repeatable uses greedy sampling. Varied allows more variation.")

                HStack {
                    Text("Temperature")
                    Slider(value: $model.temperature, in: 0...2, step: 0.1)
                        .disabled(model.sampling == .greedy)
                        .accessibilityLabel("Temperature")
                        .accessibilityValue(model.sampling == .greedy
                            ? "Not used with repeatable sampling"
                            : model.temperature.formatted(.number.precision(.fractionLength(1))))
                    Text(model.sampling == .greedy ? "Not used" : model.temperature.formatted(.number.precision(.fractionLength(1))))
                        .monospacedDigit()
                        .frame(width: 58, alignment: .trailing)
                }
                Stepper(
                    "Maximum response: \(model.maximumResponseTokens) tokens",
                    value: $model.maximumResponseTokens,
                    in: AppleModelLabRequest.responseTokenRange,
                    step: 16)
                    .accessibilityLabel("Maximum response tokens")
                    .accessibilityValue("\(model.maximumResponseTokens)")
            }
            .padding(6)
        }
        .disabled(model.phase != .idle)
    }

    private var responseCard: some View {
        GroupBox("Response") {
            VStack(alignment: .leading, spacing: 10) {
                if model.phase != .idle {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.phase == .stopping ? "Stopping safely…" : "Generating on this Mac…")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let message = model.message {
                    Label(message, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ScrollView {
                    Text(responseText)
                        .foregroundStyle(model.output.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(9)
                }
                .frame(minHeight: 150)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))

                if let metrics = model.metrics {
                    metricsView(metrics)
                }
            }
            .padding(6)
        }
    }

    private var footer: some View {
        HStack {
            Button("Copy Response", systemImage: "doc.on.doc", action: onCopy)
                .disabled(model.output.isEmpty)
                .accessibilityLabel("Copy response")
            Button("Clear Result", action: model.clearResult)
                .disabled(model.phase != .idle || (model.output.isEmpty && model.message == nil))
                .accessibilityLabel("Clear result")
            Spacer()
            if model.phase == .idle {
                Button(model.output.isEmpty ? "Run Prompt" : "Run Again", action: model.run)
                    .disabled(!model.canRun)
                    .accessibilityLabel(model.output.isEmpty ? "Run prompt" : "Run again")
                    .keyboardShortcut(.return, modifiers: [.command])
            } else {
                Button("Stop", action: model.stop)
                    .disabled(model.phase == .stopping)
                    .accessibilityLabel("Stop generation")
            }
            Button("Done", action: onDone)
                .accessibilityLabel("Done")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
    }

    private func fieldLabel(_ title: String, count: Int, limit: Int) -> some View {
        HStack {
            Text(title).font(.callout.weight(.medium))
            Spacer()
            Text("\(count) / \(limit)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(count > limit ? Color.red : Color.secondary)
        }
    }

    private var responseText: String {
        if !model.output.isEmpty { return model.output }
        if model.phase != .idle { return "Waiting for the first output…" }
        return "Run a prompt to see the private on-device response here."
    }

    private func metricsView(_ metrics: AppleModelLabMetrics) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
            GridRow {
                Text("First output").foregroundStyle(.secondary)
                Text(format(metrics.timeToFirstOutputSeconds)).monospacedDigit()
            }
            GridRow {
                Text("Total time").foregroundStyle(.secondary)
                Text(format(metrics.totalSeconds)).monospacedDigit()
            }
            GridRow {
                Text("Response tokens").foregroundStyle(.secondary)
                Text(metrics.responseTokens.map(String.init) ?? "Available on macOS 26.4+")
                    .monospacedDigit()
            }
        }
        .font(.callout)
    }

    private func format(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "Waiting…" }
        return String(format: "%.2f seconds", seconds)
    }
}
