import DisplayManagerCore
import SwiftUI

struct AutomationSettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
            if model.automationPaused {
                Section {
                    HStack {
                        Label("Automation is paused after repeated applies.", systemImage: "pause.circle")
                        Spacer()
                        Button("Resume") { model.automation?.resume() }
                    }
                }
            }

            Section {
                LabeledContent("Wait for displays after wake") {
                    HStack {
                        Slider(value: Binding { model.settleDelaySeconds } set: { model.setSettleDelaySeconds($0) }, in: 0...10, step: 0.5)
                            .frame(width: 180)
                            .accessibilityLabel("Seconds to wait after wake")
                        Text("\(model.settleDelaySeconds.formatted(.number.precision(.fractionLength(1)))) s")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            } footer: {
                FormFooter("After wake or unlock, displays can take a moment to report their ports. Automatic applies also wait until the connected displays stop changing.")
            }

            Section {
                if model.knownPorts.isEmpty {
                    Text("No ports learned yet. Use Learn Current Port in a layout's Auto Apply section.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.knownPorts) { port in
                    KnownPortRow(model: model, port: port, isThisMac: port.connection.hostModel == model.snapshots.hostModel)
                }
            } header: {
                Text("Learned Ports")
            } footer: {
                FormFooter("Names are yours. The technical label follows what macOS reports (for example “Port-USB-C@3” becomes “USB-C Port 3”). It is not a physical left or right position.")
            }

            Section("Recent Activity") {
                RecentActivityList()
                HStack {
                    Spacer()
                    Button("Show Diagnostics…") { Alerts.showDetails(title: "Diagnostics", text: model.diagnosticsText()) }
                    Button("Copy Diagnostics") { Alerts.copyToPasteboard(model.diagnosticsText()) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 620)
    }
}

private struct KnownPortRow: View {
    let model: AppModel
    let port: KnownPort
    let isThisMac: Bool
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(port.connection.technicalLabel)
                Text(isThisMac ? port.connection.hostModel : "\(port.connection.hostModel) (another Mac model)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TextField("Name", text: $name, prompt: Text("Unnamed"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .frame(width: 170)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                .accessibilityLabel("Name for \(port.connection.technicalLabel)")
            Button {
                model.deleteKnownPort(port.connection)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Forget this port name. Rules that use the port keep working.")
            .accessibilityLabel("Forget \(port.connection.technicalLabel)")
        }
        .onAppear { name = port.name }
        .onChange(of: port.name) { _, new in if !focused { name = new } }
    }

    private func commit() {
        if name != port.name { model.renameKnownPort(port.connection, to: name) }
    }
}

private struct RecentActivityList: View {
    private var log: DiagnosticsLog { DiagnosticsLog.shared }

    var body: some View {
        let entries = Array(log.entries.suffix(100).reversed())
        Group {
            if entries.isEmpty {
                Text("Nothing yet.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(entries) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: symbol(for: entry.level))
                                    .foregroundStyle(color(for: entry.level))
                                    .frame(width: 14)
                                Text(entry.date.formatted(date: .omitted, time: .standard))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                Text(entry.message)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.caption)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 170)
            }
        }
    }

    private func symbol(for level: LogLevel) -> String {
        switch level {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .notice: "checkmark.circle"
        case .info, .debug: "info.circle"
        }
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .error: .red
        case .warning: .orange
        case .notice: .green
        case .info, .debug: .secondary
        }
    }
}
