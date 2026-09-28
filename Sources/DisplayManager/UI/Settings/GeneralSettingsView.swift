import SwiftUI

struct GeneralSettingsView: View {
    let model: AppModel
    let coordinator: WindowCoordinator

    var body: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: Binding {
                    model.loginItemStatus.isOn
                } set: { _ in
                    coordinator.toggleLaunchAtLogin()
                })
                if model.loginItemStatus == .requiresApproval {
                    HStack {
                        Label("Needs your approval in System Settings.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Login Items…") { LoginItemController.openSystemSettingsLoginItems() }
                    }
                }
                if !AppInfo.isInstalledInApplications {
                    Text("DisplayManager is not running from /Applications. Install it with ./install.sh so Launch at Login keeps working.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle(isOn: Binding { model.autoApplyEnabled } set: { model.setAutoApplyEnabled($0) }) {
                    Text("Auto Apply")
                    Text("Apply a layout when its displays are connected and at app launch. Set the conditions per layout in the Layout Manager.")
                }
                Toggle(isOn: Binding { model.reapplyAfterWake } set: { model.setReapplyAfterWake($0) }) {
                    Text("Reapply After Wake")
                    Text("Apply the matching layout again after the Mac wakes from sleep.")
                }
            }

            Section {
                LabeledContent("Version", value: "\(AppInfo.version) (\(AppInfo.build))")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 360)
        .onAppear { model.refreshLoginItemStatus() }
    }
}
