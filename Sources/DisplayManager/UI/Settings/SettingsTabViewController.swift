import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general
    case automation
    case displayplacer
    case data

    var title: String {
        switch self {
        case .general: "General"
        case .automation: "Automation"
        case .displayplacer: "displayplacer"
        case .data: "Data"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .automation: "wand.and.stars"
        case .displayplacer: "terminal"
        case .data: "externaldrive"
        }
    }
}

/// Native Settings window with toolbar tabs. Each tab is a SwiftUI view.
@MainActor
final class SettingsTabViewController: NSTabViewController {
    init(model: AppModel, coordinator: WindowCoordinator) {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        for tab in SettingsTab.allCases {
            let controller = Self.makeController(for: tab, model: model, coordinator: coordinator)
            controller.sizingOptions = [.preferredContentSize]
            let item = NSTabViewItem(viewController: controller)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: tab.title)
            item.identifier = tab.rawValue
            addTabViewItem(item)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private static func makeController(for tab: SettingsTab, model: AppModel, coordinator: WindowCoordinator) -> NSHostingController<AnyView> {
        let view: AnyView = switch tab {
        case .general: AnyView(GeneralSettingsView(model: model, coordinator: coordinator))
        case .automation: AnyView(AutomationSettingsView(model: model))
        case .displayplacer: AnyView(DisplayplacerSettingsView(model: model))
        case .data: AnyView(DataSettingsView(model: model, coordinator: coordinator))
        }
        return NSHostingController(rootView: view)
    }

    func select(_ tab: SettingsTab) {
        selectedTabViewItemIndex = SettingsTab.allCases.firstIndex(of: tab) ?? 0
        view.window?.title = tab.title
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        view.window?.title = tabViewItem?.label ?? "Settings"
    }
}
