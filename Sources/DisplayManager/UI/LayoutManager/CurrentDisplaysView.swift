import DisplayManagerCore
import SwiftUI

/// The live configuration: preview, per-display settings, identity, physical port, current command.
struct CurrentDisplaysView: View {
    let model: AppModel
    let coordinator: WindowCoordinator
    @State private var isRefreshing = false

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Current Displays").font(.title2.weight(.semibold))
                        Text(model.currentLayoutState.menuTitle).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(isRefreshing ? "Refreshing…" : "Refresh") { refresh() }
                        .disabled(isRefreshing)
                    Button("Save as Layout…") { coordinator.saveCurrentLayout() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!model.displayplacerStatus.isUsable)
                        .help(model.displayplacerStatus.isUsable ? "Save the current arrangement as a layout" : model.displayplacerStatus.summary)
                }
                if !model.displayplacerStatus.isUsable {
                    HStack {
                        Label(model.displayplacerStatus.summary, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Spacer()
                        Button("Open displayplacer Settings…") { coordinator.showSettings(tab: .displayplacer) }
                    }
                } else if let error = model.snapshotError {
                    HStack {
                        Label(error.userMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        if let detail = error.diagnosticDetail {
                            Spacer()
                            Button("Details…") { Alerts.showDetails(title: "displayplacer output", text: detail) }
                        }
                    }
                }
                if let snapshot = model.snapshot, case .unavailable(let reason) = snapshot.topologyStatus {
                    Label("Port detection is not available: \(reason)", systemImage: "info.circle").foregroundStyle(.secondary)
                }
            }

            if let snapshot = model.snapshot {
                Section("Arrangement") {
                    LayoutPreviewView(preview: PreviewGeometry.model(for: snapshot))
                }
                ForEach(snapshot.displays) { display in
                    LiveDisplaySection(model: model, snapshot: snapshot, display: display)
                }
                if let command = snapshot.parsedList?.commandLine {
                    Section("Current Command") {
                        RawCommandView(command: command, note: "The command displayplacer reports for the current configuration.")
                    }
                }
            } else {
                Section {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Reading the connected displays…").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func refresh() {
        isRefreshing = true
        Task {
            await model.refreshDisplayplacer()
            await model.refreshSnapshot()
            isRefreshing = false
        }
    }
}

private struct LiveDisplaySection: View {
    let model: AppModel
    let snapshot: SystemSnapshot
    let display: LiveDisplay

    private var screen: ScreenSetting? {
        snapshot.configuration?.first { screen in
            screen.displayIDs.contains { $0.caseInsensitiveCompare(display.persistentID) == .orderedSame }
        }
    }

    private var parsed: ParsedScreen? { snapshot.parsedList?.screen(persistentID: display.persistentID) }

    var body: some View {
        Section {
            LabeledContent("Connection", value: connectionText)
            if let transport = display.transportDescription {
                LabeledContent("Transport", value: transport)
            }
            if let screen, !screen.enabled {
                LabeledContent("State", value: "Turned off")
            } else {
                if let size = screen?.resolution ?? display.bounds?.size {
                    LabeledContent("Resolution", value: "\(size.width) × \(size.height)")
                }
                if let hz = screen?.refreshRate { LabeledContent("Refresh rate", value: "\(hz) Hz") }
                if let scaling = screen?.scaling { LabeledContent("Scaling", value: scaling ? "On (HiDPI)" : "Off") }
                if let depth = screen?.colorDepth { LabeledContent("Color depth", value: "\(depth)-bit") }
                LabeledContent("Rotation", value: "\(screen?.effectiveRotation ?? display.rotation)°")
                if let origin = screen?.origin ?? display.bounds?.origin {
                    LabeledContent("Origin", value: "\(origin.x), \(origin.y)")
                }
                if let screen, screen.isMirrorSet {
                    let names = screen.displayIDs.compactMap { snapshot.display(persistentID: $0)?.name }
                    LabeledContent("Mirroring", value: names.joined(separator: " + "))
                }
            }
            DisclosureGroup("Identity") {
                LabeledContent("Persistent id") { Text(display.persistentID).textSelection(.enabled).font(.system(.caption, design: .monospaced)) }
                if let serial = display.serialID {
                    LabeledContent("Serial id") { Text(serial).textSelection(.enabled).font(.system(.caption, design: .monospaced)) }
                }
                if let contextual = display.contextualID { LabeledContent("Contextual id", value: "\(contextual)") }
                if let vendor = display.vendorID { LabeledContent("Vendor", value: "\(vendor)\(display.manufacturerID.map { " (\($0))" } ?? "")") }
                if let product = display.productID { LabeledContent("Product", value: "\(product)") }
                if let type = display.typeDescription ?? parsed?.typeDescription { LabeledContent("Type", value: type) }
            }
        } header: {
            HStack {
                Text(display.name)
                if display.isMain { Text("Main").font(.caption).foregroundStyle(.secondary) }
                if display.isBuiltIn { Text("Built-in").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private var connectionText: String {
        switch display.connection {
        case .builtIn:
            return "Built-in"
        case .external(let fingerprint):
            // "USB-C Port 3 · Desk Port" when the port has a name.
            let name = model.knownPorts.first { $0.connection == fingerprint }?.name.trimmingCharacters(in: .whitespaces) ?? ""
            return name.isEmpty ? fingerprint.technicalLabel : "\(fingerprint.technicalLabel) · \(name)"
        case .unidentified(let reason):
            return "Port unknown: \(reason.userMessage)"
        }
    }
}
