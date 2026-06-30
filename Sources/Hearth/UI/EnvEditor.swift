// SPDX-License-Identifier: MIT

import SwiftUI
import SupervisorCore

/// A focused editor for the runner's environment variables, opened from the
/// Preferences "Set Env" button. Structured key/value rows beat a free-text field:
/// adding a variable is an obvious button, not a hidden Option+Return. Edits are
/// committed back to the config only on Done; Cancel discards them.
struct EnvEditorView: View {
    @State private var rows: [EnvRow]
    let onDone: ([String: String]) -> Void
    let onCancel: () -> Void

    init(env: [String: String],
         onDone: @escaping ([String: String]) -> Void,
         onCancel: @escaping () -> Void) {
        _rows = State(initialValue: env.sorted { $0.key < $1.key }.map { EnvRow(key: $0.key, value: $0.value) })
        self.onDone = onDone
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Runner environment").font(.headline)
                Text("Variables set on the managed runner when Hearth launches it, for example OLLAMA_LOAD_TIMEOUT or OLLAMA_KEEP_ALIVE. OLLAMA_HOST is managed by Hearth from the Host and Port, so it is not set here.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(spacing: 6) {
                    if rows.isEmpty {
                        Text("No variables yet. Add one below.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 20)
                    }
                    ForEach($rows) { $row in
                        HStack(spacing: 8) {
                            TextField("NAME", text: $row.key)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                            Text("=").foregroundStyle(.secondary)
                            TextField("value", text: $row.value)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                            Button {
                                rows.removeAll { $0.id == row.id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Remove this variable")
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 120, maxHeight: 260)

            Button {
                rows.append(EnvRow(key: "", value: ""))
            } label: {
                Label("Add variable", systemImage: "plus")
            }
            .buttonStyle(.borderless)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Done") { onDone(RunnerEnvEditor.fold(rows.map { ($0.key, $0.value) })) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

private struct EnvRow: Identifiable {
    let id = UUID()
    var key: String
    var value: String
}
