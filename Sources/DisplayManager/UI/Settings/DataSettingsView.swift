import DisplayManagerCore
import SwiftUI

struct DataSettingsView: View {
    let model: AppModel
    let coordinator: WindowCoordinator

    var body: some View {
        Form {
            Section {
                LabeledContent("Saved", value: [
                    counted(model.profiles.count, "layout"),
                    counted(model.rules.count, "rule"),
                    counted(model.knownPorts.count, "learned port"),
                ].joined(separator: ", "))
                LabeledContent("File") {
                    Text((model.store.fileURL.path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                if let error = model.persistenceError {
                    Label("Saving failed: \(error.userMessage) Changes are kept in memory and saved again with the next change.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                HStack {
                    Button("Show Data Folder") { coordinator.showDataFolder() }
                    Spacer()
                    Button("Import…") { coordinator.importLayouts() }
                    Button("Export…") { coordinator.exportLayouts() }
                        .disabled(model.profiles.isEmpty)
                }
            } footer: {
                FormFooter("Exports are JSON files with layouts, their Auto Apply rules and port names. Import can add to your layouts or replace them. Replace All saves a backup in the data folder first.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 260)
    }
}
