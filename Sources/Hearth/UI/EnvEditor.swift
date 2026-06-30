// SPDX-License-Identifier: MIT

import SwiftUI
import SupervisorCore

/// A focused editor for the runner's environment variables, opened from the
/// Preferences "Set Env" button. The variable name is a dropdown of the runner's
/// known variables (Ollama's set is documented and finite), with a Custom entry for
/// anything off-list, so the common case is never typed. Edits commit to the config
/// only on Done; Cancel discards them.
struct EnvEditorView: View {
    @State private var rows: [EnvRow]
    private let catalog: [RunnerEnvVar]
    let onDone: ([String: String]) -> Void
    let onCancel: () -> Void

    init(env: [String: String],
         runner: String,
         onDone: @escaping ([String: String]) -> Void,
         onCancel: @escaping () -> Void) {
        _rows = State(initialValue: env.sorted { $0.key < $1.key }.map { EnvRow(name: $0.key, value: $0.value) })
        self.catalog = RunnerEnvCatalog.variables(for: runner)
        self.onDone = onDone
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Runner environment").font(.headline)
                Text("Variables set on the managed runner when Hearth launches it. Pick from the list or choose Custom for one not shown. OLLAMA_HOST is managed by Hearth from the Host and Port, so it is not listed.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(spacing: 10) {
                    if rows.isEmpty {
                        Text("No variables yet. Add one below.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 20)
                    }
                    ForEach($rows) { $row in
                        EnvRowEditor(row: $row, catalog: catalog) {
                            rows.removeAll { $0.id == row.id }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 130, maxHeight: 280)

            Button {
                // A new row starts on the first catalog variable (if any) so the
                // common path is pick-then-fill, never typing a name.
                rows.append(EnvRow(name: catalog.first?.name ?? "", value: ""))
            } label: {
                Label("Add variable", systemImage: "plus")
            }
            .buttonStyle(.borderless)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Done") { onDone(RunnerEnvEditor.fold(rows.map { ($0.name, $0.value) })) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

/// One row: a name dropdown (plus a text field when Custom), an equals sign, the
/// value, and a delete button, with the selected variable's description beneath.
private struct EnvRowEditor: View {
    @Binding var row: EnvRow
    let catalog: [RunnerEnvVar]
    let onDelete: () -> Void

    /// Sentinel tag for the Custom entry; the U+0001 prefix cannot collide with a
    /// real variable name.
    private static let customTag = "\u{1}custom"

    private var spec: RunnerEnvVar? { catalog.first { $0.name == row.name } }
    private var isCustom: Bool { spec == nil }

    private var selection: Binding<String> {
        Binding(
            get: { isCustom ? Self.customTag : row.name },
            set: { picked in
                if picked == Self.customTag {
                    // Switching to Custom from a known variable clears the name so
                    // the text field starts empty; a custom name already typed stays.
                    if catalog.contains(where: { $0.name == row.name }) { row.name = "" }
                } else {
                    row.name = picked
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if catalog.isEmpty {
                    TextField("NAME", text: $row.name)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                } else {
                    Picker("", selection: selection) {
                        ForEach(catalog, id: \.name) { Text($0.name).tag($0.name) }
                        Divider()
                        Text("Custom\u{2026}").tag(Self.customTag)
                    }
                    .labelsHidden()
                    .frame(width: 230)
                    if isCustom {
                        TextField("NAME", text: $row.name)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 150)
                    }
                }
                Text("=").foregroundStyle(.secondary)
                TextField(spec?.example ?? "value", text: $row.value)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Button(action: onDelete) { Image(systemName: "minus.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove this variable")
            }
            if let spec {
                Text(spec.summary).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct EnvRow: Identifiable {
    let id = UUID()
    var name: String
    var value: String
}
