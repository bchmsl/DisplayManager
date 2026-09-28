import SwiftUI

/// A selectable, monospaced command with a Copy button.
struct RawCommandView: View {
    let command: String
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal) {
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.6)))
            .accessibilityLabel("displayplacer command")
            HStack {
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy Raw Command") { Alerts.copyToPasteboard(command) }
            }
        }
    }
}
