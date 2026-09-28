import DisplayManagerCore
import SwiftUI

/// Edits the one Auto Apply rule of a profile: on/off, optional port per external display, triggers.
///
/// The display-set condition is implicit: the rule only matches when exactly this layout's displays are connected.
struct AutoApplyRuleEditor: View {
    let model: AppModel
    let profile: LayoutProfile

    private var rule: AutoApplyRule? { model.rule(for: profile.id) }

    var body: some View {
        Section {
            Toggle("Apply automatically when these displays are connected", isOn: enabledBinding)
            if let rule, rule.isEnabled {
                if profile.externalDisplays.isEmpty {
                    Text("This layout has no external displays. It is applied when only these displays are connected.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(uniqueExternalDisplays, id: \.persistentID) { display in
                        PortRequirementRow(model: model, profile: profile, rule: rule, display: display)
                    }
                }
                triggers(rule)
                notes(rule)
            }
        } header: {
            Text("Auto Apply")
        } footer: {
            FormFooter("A monitor matches by its identity. Choosing a port also requires the monitor to be connected through that physical port.")
        }
    }

    private var uniqueExternalDisplays: [DisplayInfo] {
        var seen = Set<String>()
        return profile.externalDisplays.filter { seen.insert($0.persistentID).inserted }
    }

    private var enabledBinding: Binding<Bool> {
        Binding {
            rule?.isEnabled ?? false
        } set: { enabled in
            var updated = rule ?? AutoApplyRule(profileID: profile.id)
            updated.isEnabled = enabled
            model.setRule(updated, for: profile.id)
        }
    }

    @ViewBuilder
    private func triggers(_ rule: AutoApplyRule) -> some View {
        LabeledContent("Apply") {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("At app launch", isOn: triggerBinding(rule, \.launch))
                Toggle("When displays connect or change", isOn: triggerBinding(rule, \.displayConnect))
                Toggle("After wake from sleep", isOn: triggerBinding(rule, \.wake))
            }
        }
    }

    private func triggerBinding(_ rule: AutoApplyRule, _ keyPath: WritableKeyPath<RuleTriggers, Bool>) -> Binding<Bool> {
        Binding {
            rule.triggers[keyPath: keyPath]
        } set: { value in
            var updated = rule
            updated.triggers[keyPath: keyPath] = value
            model.setRule(updated, for: profile.id)
        }
    }

    @ViewBuilder
    private func notes(_ rule: AutoApplyRule) -> some View {
        if !model.autoApplyEnabled {
            Label("Auto Apply is turned off in the menu, so this rule is not used.", systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if rule.triggers.wake, !model.reapplyAfterWake {
            Label("Reapply After Wake is turned off in the menu, so the wake trigger is not used.", systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if rule.triggers.isEmpty {
            Label("Choose at least one moment to apply this layout.", systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
        }
        let conflicts = model.conflictingRules(for: rule).compactMap { model.profile(id: $0.profileID)?.name }
        if !conflicts.isEmpty {
            Label(
                "“\(conflicts.joined(separator: "”, “"))” has the same conditions. The layout higher in the list is applied.",
                systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
        }
        if let snapshot = model.snapshot {
            let evaluation = RuleMatcher.evaluate(rule: rule, profile: profile, snapshot: snapshot)
            if evaluation.isSatisfied {
                Label("Matches the connected displays now.", systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Does not match right now:").font(.callout).foregroundStyle(.secondary)
                    ForEach(Array(evaluation.mismatches.enumerated()), id: \.offset) { _, mismatch in
                        Text("• \(mismatch.description)").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// "Port: [Any port | Desk Port (USB-C Port 3) | …]" plus Learn Current Port for one external display.
private struct PortRequirementRow: View {
    let model: AppModel
    let profile: LayoutProfile
    let rule: AutoApplyRule
    let display: DisplayInfo

    @State private var learnError: String?
    @State private var isLearning = false
    @State private var portName = ""
    @FocusState private var nameFocused: Bool

    private var requirement: ConnectionRequirement? { rule.requirement(for: display.persistentID) }

    /// Ports learned on this Mac model, plus the selected one if it came from somewhere else.
    private var choices: [KnownPort] {
        let host = model.snapshots.hostModel
        var ports = model.knownPorts.filter { $0.connection.hostModel == host }
        if let selected = requirement?.connection, !ports.contains(where: { $0.connection == selected }) {
            ports.append(model.knownPorts.first { $0.connection == selected } ?? KnownPort(connection: selected, name: ""))
        }
        return ports
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker(selection: selectionBinding) {
                    Text("Any port").tag(String?.none)
                    if !choices.isEmpty { Divider() }
                    ForEach(choices) { port in
                        Text(port.displayLabel).tag(String?.some(port.connection.key))
                    }
                } label: {
                    Text(display.name).lineLimit(1)
                }
                Button(isLearning ? "Reading…" : "Learn Current Port") { learn() }
                    .disabled(isLearning)
                    .help("Use the port \(display.name) is connected to right now.")
            }
            if let saved = display.connection, saved != requirement?.connection {
                Button("Use port from when this layout was saved: \(model.knownPorts.label(for: saved))") {
                    setRequirement(saved)
                }
                .buttonStyle(.link)
                .font(.callout)
            }
            if let selected = requirement?.connection {
                HStack {
                    Text("Port name").foregroundStyle(.secondary)
                    TextField("Port name", text: $portName, prompt: Text("For example “Desk Port”"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 220)
                        .focused($nameFocused)
                        .onSubmit { model.renameKnownPort(selected, to: portName) }
                        .onChange(of: nameFocused) { _, focused in
                            if !focused { model.renameKnownPort(selected, to: portName) }
                        }
                    Text(selected.technicalLabel).font(.caption).foregroundStyle(.secondary)
                }
                .onAppear { portName = currentName(selected) }
                .onChange(of: selected) { _, new in portName = currentName(new) }
            }
            Text(liveStatus).font(.caption).foregroundStyle(.secondary)
            if let learnError {
                Label(learnError, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func currentName(_ connection: ConnectionFingerprint) -> String {
        model.knownPorts.first { $0.connection == connection }?.name ?? ""
    }

    /// Where the display is connected right now.
    private var liveStatus: String {
        guard let snapshot = model.snapshot else { return "Connection: checking…" }
        let resolution = DisplayResolver.resolve(profile: profile, snapshot: snapshot)
        guard let liveID = resolution.liveID(forSaved: display.persistentID), let live = snapshot.display(persistentID: liveID) else {
            return "Not connected now"
        }
        switch live.connection {
        case .unidentified(let reason): return "Connected now, port unknown: \(reason.userMessage)"
        default: return "Connected now to \(model.portLabel(for: live.connection))"
        }
    }

    private var selectionBinding: Binding<String?> {
        Binding {
            requirement?.connection.key
        } set: { key in
            setRequirement(key.flatMap { key in choices.first { $0.connection.key == key }?.connection })
        }
    }

    private func setRequirement(_ connection: ConnectionFingerprint?) {
        var updated = rule
        updated.connectionRequirements.removeAll { $0.persistentID == display.persistentID }
        if let connection {
            updated.connectionRequirements.append(ConnectionRequirement(persistentID: display.persistentID, connection: connection))
        }
        learnError = nil
        model.setRule(updated, for: profile.id)
    }

    private func learn() {
        isLearning = true
        learnError = nil
        Task {
            let result = await model.learnCurrentPort(profileID: profile.id, persistentID: display.persistentID)
            isLearning = false
            switch result {
            case .success(let fingerprint): setRequirement(fingerprint)
            case .failure(let error): learnError = error.message
            }
        }
    }
}
