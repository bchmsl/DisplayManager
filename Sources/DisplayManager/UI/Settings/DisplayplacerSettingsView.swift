import AppKit
import DisplayManagerCore
import SwiftUI

struct DisplayplacerSettingsView: View {
    let model: AppModel
    @State private var isChecking = false

    private static let installCommand = "brew install displayplacer"
    private static let projectURL = URL(string: "https://github.com/jakehilborn/displayplacer")

    private var status: DisplayplacerStatus { model.displayplacerStatus }

    var body: some View {
        Form {
            Section {
                HStack {
                    Label(status.summary, systemImage: status.isUsable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(status.isUsable ? Color.green : Color.orange)
                    Spacer()
                    Button(isChecking ? "Checking…" : "Re-check") { recheck() }
                        .disabled(isChecking)
                }
                if let path = status.path {
                    LabeledContent("Path") {
                        Text(path).textSelection(.enabled).font(.system(.callout, design: .monospaced))
                    }
                    if let resolved = status.resolvedPath {
                        LabeledContent("Links to") {
                            Text(resolved).textSelection(.enabled).font(.system(.caption, design: .monospaced)).lineLimit(2)
                        }
                    }
                    LabeledContent("Found by", value: sourceText)
                }
                if let version = status.version {
                    LabeledContent("Version", value: version.description)
                }
            }

            Section {
                LabeledContent("Custom path") {
                    Text(model.displayplacerPathOverride ?? "None (search automatically)")
                        .font(.callout)
                        .foregroundStyle(model.displayplacerPathOverride == nil ? .secondary : .primary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                if status.overrideIsInvalid {
                    Label("The custom path is not an executable file. The automatic search was used instead.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    Button("Reset") { setOverride(nil) }
                        .disabled(model.displayplacerPathOverride == nil)
                    Button("Choose…") { choose() }
                }
            } footer: {
                FormFooter("Searched automatically: /opt/homebrew/bin, /usr/local/bin, PATH, ~/.local/bin, ~/bin and /opt/local/bin.")
            }

            Section("Install") {
                Text("DisplayManager uses displayplacer to read and change display layouts. It never installs software itself. Install it with Homebrew:")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(Self.installCommand)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(0.6)))
                    Button("Copy") { Alerts.copyToPasteboard(Self.installCommand) }
                    Spacer()
                    if let url = Self.projectURL {
                        Link("Project page", destination: url)
                    }
                }
                Text("Version 1.4.0 or newer is needed. Click Re-check after installing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 570)
    }

    private var sourceText: String {
        switch status.source {
        case .userOverride: "Custom path"
        case .standardLocation: "Standard location"
        case .searchPath: "Search path"
        case nil: "—"
        }
    }

    private func recheck() {
        isChecking = true
        Task {
            await model.refreshDisplayplacer()
            await model.refreshSnapshot()
            isChecking = false
        }
    }

    private func setOverride(_ path: String?) {
        isChecking = true
        Task {
            await model.setDisplayplacerPathOverride(path)
            isChecking = false
        }
    }

    private func choose() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose the displayplacer executable"
        panel.prompt = "Choose"
        for candidate in ["/opt/homebrew/bin", "/usr/local/bin"] where FileManager.default.fileExists(atPath: candidate) {
            panel.directoryURL = URL(fileURLWithPath: candidate, isDirectory: true)
            break
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            Alerts.showError("Not an executable file", message: "“\(url.lastPathComponent)” cannot be run. Choose the displayplacer program itself.")
            return
        }
        setOverride(url.path)
    }
}
