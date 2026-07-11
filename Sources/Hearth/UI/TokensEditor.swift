// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import SupervisorCore

/// A focused editor for named control tokens, opened from the Preferences
/// "Edit Tokens" button. Each caller of a shared control endpoint gets its own
/// named secret, and every start/stop/restart is logged with the token's name,
/// so the event history says who acted. Edits commit only on Done.
struct TokensEditorView: View {
    @State private var rows: [TokenRow]
    let heading: String
    let explanation: String
    let namePlaceholder: String
    let onDone: ([String: String]) -> Void
    let onCancel: () -> Void

    init(tokens: [String: String],
         heading: String = "Named control tokens",
         explanation: String = "Give each caller of the control endpoint its own token; start, stop, and restart actions are then logged with the token's name, so the event history says who acted. Name them after the caller (phone-kitchen, laptop). The main bearer token keeps working and is logged as “default”, so avoid that name here.",
         namePlaceholder: String = "name (e.g. phone-kitchen)",
         onDone: @escaping ([String: String]) -> Void,
         onCancel: @escaping () -> Void) {
        _rows = State(initialValue: tokens.sorted { $0.key < $1.key }
            .map { TokenRow(name: $0.key, secret: $0.value) })
        self.heading = heading
        self.explanation = explanation
        self.namePlaceholder = namePlaceholder
        self.onDone = onDone
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(heading).font(.headline)
                Text(explanation)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(spacing: 10) {
                    if rows.isEmpty {
                        Text("No named tokens yet. Add one below.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 20)
                    }
                    ForEach($rows) { $row in
                        HStack(spacing: 8) {
                            TextField(namePlaceholder, text: $row.name)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 170)
                            TextField("secret", text: $row.secret)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                            Button("Generate") { row.secret = PreferencesView.randomToken() }
                                .buttonStyle(.borderless)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(row.secret, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .disabled(row.secret.isEmpty)
                            .help("Copy this token")
                            .accessibilityLabel("Copy token")
                            Button {
                                rows.removeAll { $0.id == row.id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Remove this token")
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 110, maxHeight: 260)

            Button {
                rows.append(TokenRow(name: "", secret: PreferencesView.randomToken()))
            } label: {
                Label("Add token", systemImage: "plus")
            }
            .buttonStyle(.borderless)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Done") { onDone(folded) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    /// Rows folded to the config dictionary: blank names or secrets are dropped
    /// (half-filled rows are abandoned edits, not tokens), a duplicated name
    /// keeps the last edit, matching how the env editor folds.
    private var folded: [String: String] {
        var tokens: [String: String] = [:]
        for row in rows {
            let name = row.name.trimmingCharacters(in: .whitespaces)
            let secret = row.secret.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !secret.isEmpty else { continue }
            tokens[name] = secret
        }
        return tokens
    }
}

private struct TokenRow: Identifiable {
    let id = UUID()
    var name: String
    var secret: String
}
