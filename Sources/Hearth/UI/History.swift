// SPDX-License-Identifier: MIT

import AppKit
import Charts
import SwiftUI
import SupervisorCore

@MainActor
final class HistoryController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var hosting: NSHostingController<HistoryView>?

    func show() {
        let view = HistoryView(
            eventLines: EventLogStore.recent(EventLogStore.maxLines),
            metrics: MetricsHistoryStore.load().samples)
        if let hosting {
            hosting.rootView = view
        } else {
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Hearth History"
            window.styleMask = [.titled, .closable, .resizable]
            window.setContentSize(NSSize(width: 760, height: 680))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.hosting = hosting
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        window = nil
        hosting = nil
    }
}

struct HistoryView: View {
    let eventLines: [String]
    let metrics: [MetricsSample]

    private var incidents: [IncidentHistory.Incident] {
        IncidentHistory.build(eventLines)
    }

    private var stats: EventStats.Summary {
        EventStats.summarize(eventLines)
    }

    private var restartDates: [Date] {
        eventLines.compactMap(EventLog.parse).compactMap { entry in
            let message = entry.message
            return message.hasPrefix("Restarted") || message == "Maintenance restart"
                || message.hasPrefix("Memory limit restart") ? entry.at : nil
        }
    }

    private var memorySamples: [MetricsSample] {
        metrics.filter { $0.memoryPercent != nil }
    }

    private var rssSamples: [MetricsSample] {
        metrics.filter { $0.runnerResidentBytes != nil }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                summaryCards
                if !memorySamples.isEmpty { memoryChart }
                if !rssSamples.isEmpty { rssChart }
                incidentsSection
                recentActivitySection
            }
            .padding(22)
        }
        .frame(minWidth: 650, minHeight: 520)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Health history").font(.title2).fontWeight(.semibold)
                Text("Incidents and resource pressure retained on this Mac.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Copy Summary") { copySummary() }
        }
    }

    private var summaryCards: some View {
        HStack(spacing: 10) {
            card("Incidents", "\(stats.downCount)")
            card("Crash loops", "\(stats.crashLoopCount)")
            card("Mean recovery", stats.meanRecovery.map(StatusText.duration) ?? "None")
            card("Memory peak", metrics.compactMap(\.memoryPercent).max().map { "\($0)%" } ?? "Unknown")
        }
    }

    private func card(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private var memoryChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("System memory").font(.headline)
            Chart {
                ForEach(memorySamples, id: \.at) { sample in
                    if let percent = sample.memoryPercent {
                        LineMark(x: .value("Time", sample.at), y: .value("Percent", percent))
                            .foregroundStyle(.orange)
                    }
                }
                ForEach(restartDates, id: \.self) { date in
                    RuleMark(x: .value("Restart", date))
                        .foregroundStyle(.red.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartYScale(domain: 0...100)
            .chartYAxisLabel("Used %")
            .frame(height: 180)
            Text("Red markers are runner restarts.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var rssChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Runner memory").font(.headline)
            Chart {
                ForEach(rssSamples, id: \.at) { sample in
                    if let bytes = sample.runnerResidentBytes {
                        LineMark(
                            x: .value("Time", sample.at),
                            y: .value("GiB", Double(bytes) / 1_073_741_824))
                            .foregroundStyle(.blue)
                    }
                }
                ForEach(restartDates, id: \.self) { date in
                    RuleMark(x: .value("Restart", date))
                        .foregroundStyle(.red.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartYAxisLabel("GiB")
            .frame(height: 180)
        }
    }

    private var incidentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Incidents").font(.headline)
            if incidents.isEmpty {
                Text("No runner failures in the retained history.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(incidents.reversed().enumerated()), id: \.offset) { _, incident in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: incident.recoveredAt == nil
                              ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(incident.recoveredAt == nil ? .red : .green)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(incident.reason).fontWeight(.medium)
                            Text(incidentLine(incident)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent activity").font(.headline)
            ForEach(Array(eventLines.suffix(30).reversed().enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func incidentLine(_ incident: IncidentHistory.Incident) -> String {
        let started = incident.startedAt.formatted(date: .abbreviated, time: .standard)
        guard let duration = incident.recoveryTime else { return "\(started) - not yet recovered" }
        return "\(started) - recovered in \(StatusText.duration(duration))"
    }

    private func copySummary() {
        var lines = ["Hearth history", "Incidents: \(stats.downCount)", "Crash loops: \(stats.crashLoopCount)"]
        if let mean = stats.meanRecovery { lines.append("Mean recovery: \(StatusText.duration(mean))") }
        if let longest = stats.longestRecovery { lines.append("Longest recovery: \(StatusText.duration(longest))") }
        if !incidents.isEmpty {
            lines.append("Recent incidents:")
            for incident in incidents.suffix(10) {
                lines.append("  \(incidentLine(incident)): \(incident.reason)")
            }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
