import Foundation

/// One rectangle to draw in a layout preview (a single display or a mirror set).
public struct PreviewItem: Hashable, Sendable, Identifiable {
    public var id: String
    public var names: [String]
    /// Position and size in global points.
    public var rect: DisplayRect
    public var resolution: DisplaySize?
    public var refreshRate: Int?
    public var rotation: Int
    public var isMain: Bool
    public var isConnected: Bool

    public init(id: String, names: [String], rect: DisplayRect, resolution: DisplaySize?, refreshRate: Int?, rotation: Int, isMain: Bool, isConnected: Bool) {
        self.id = id
        self.names = names
        self.rect = rect
        self.resolution = resolution
        self.refreshRate = refreshRate
        self.rotation = rotation
        self.isMain = isMain
        self.isConnected = isConnected
    }

    public var isMirrored: Bool { names.count > 1 }
}

public struct PreviewFrame: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct PreviewModel: Hashable, Sendable {
    public var items: [PreviewItem]
    /// Names of displays the layout turns off.
    public var disabledNames: [String]
}

/// Builds proportional previews from saved or live settings. No screenshots.
public enum PreviewGeometry {
    /// Preview of a saved profile. Sizes come from saved bounds when present (correct for rotation),
    /// otherwise from the resolution, swapped for 90° and 270°.
    public static func model(for profile: LayoutProfile, connectedIDs: Set<String>) -> PreviewModel {
        let connected = Set(connectedIDs.map { $0.lowercased() })
        var items: [PreviewItem] = []
        var disabled: [String] = []
        for screen in profile.screens {
            let infos = screen.displayIDs.map(profile.displayInfo(for:))
            guard screen.enabled else {
                disabled += infos.map(\.name)
                continue
            }
            guard let first = infos.first else { continue }
            let size = displaySize(bounds: first.bounds, resolution: screen.resolution, rotation: screen.effectiveRotation)
            let origin = screen.origin ?? .zero
            items.append(PreviewItem(
                id: screen.displayIDs.joined(separator: "+"),
                names: infos.map(\.name),
                rect: DisplayRect(origin: origin, size: size),
                resolution: screen.resolution,
                refreshRate: screen.refreshRate,
                rotation: screen.effectiveRotation,
                isMain: origin == .zero,
                isConnected: infos.allSatisfy { connected.contains($0.persistentID.lowercased()) }
            ))
        }
        return PreviewModel(items: items, disabledNames: disabled)
    }

    /// Preview of the live configuration. Uses CoreGraphics bounds when available.
    public static func model(for snapshot: SystemSnapshot) -> PreviewModel {
        var items: [PreviewItem] = []
        var disabled: [String] = []
        if let configuration = snapshot.configuration {
            for screen in configuration {
                let displays = screen.displayIDs.compactMap(snapshot.display(persistentID:))
                let names = displays.isEmpty ? screen.displayIDs.map { "Display \($0.prefix(8))" } : displays.map(\.name)
                guard screen.enabled else {
                    disabled += names
                    continue
                }
                let size = displaySize(bounds: displays.first?.bounds, resolution: screen.resolution, rotation: screen.effectiveRotation)
                let origin = screen.origin ?? displays.first?.bounds?.origin ?? .zero
                items.append(PreviewItem(
                    id: screen.displayIDs.joined(separator: "+"),
                    names: names,
                    rect: DisplayRect(origin: origin, size: size),
                    resolution: screen.resolution,
                    refreshRate: screen.refreshRate,
                    rotation: screen.effectiveRotation,
                    isMain: origin == .zero,
                    isConnected: true
                ))
            }
        } else {
            for display in snapshot.displays {
                guard let bounds = display.bounds else { continue }
                items.append(PreviewItem(
                    id: display.persistentID,
                    names: [display.name],
                    rect: bounds,
                    resolution: bounds.size,
                    refreshRate: nil,
                    rotation: display.rotation,
                    isMain: display.isMain,
                    isConnected: true
                ))
            }
        }
        return PreviewModel(items: items, disabledNames: disabled)
    }

    static func displaySize(bounds: DisplayRect?, resolution: DisplaySize?, rotation: Int) -> DisplaySize {
        // Bounds are captured together with the screen settings, so they already reflect the rotation.
        if let bounds, bounds.width > 0, bounds.height > 0 { return bounds.size }
        guard let resolution, resolution.width > 0, resolution.height > 0 else { return DisplaySize(width: 1920, height: 1080) }
        return rotation == 90 || rotation == 270 ? resolution.transposed : resolution
    }

    /// Scales items uniformly into a canvas, keeping proportions and relative positions. y grows downward.
    public static func frames(for items: [PreviewItem], canvasWidth: Double, canvasHeight: Double, padding: Double) -> [String: PreviewFrame] {
        guard !items.isEmpty, canvasWidth > 0, canvasHeight > 0 else { return [:] }
        let minX = items.map { Double($0.rect.x) }.min() ?? 0
        let minY = items.map { Double($0.rect.y) }.min() ?? 0
        let maxX = items.map { Double($0.rect.x + $0.rect.width) }.max() ?? 1
        let maxY = items.map { Double($0.rect.y + $0.rect.height) }.max() ?? 1
        let contentWidth = max(maxX - minX, 1)
        let contentHeight = max(maxY - minY, 1)
        let availableWidth = max(canvasWidth - 2 * padding, 1)
        let availableHeight = max(canvasHeight - 2 * padding, 1)
        let scale = min(availableWidth / contentWidth, availableHeight / contentHeight)
        let offsetX = (canvasWidth - contentWidth * scale) / 2
        let offsetY = (canvasHeight - contentHeight * scale) / 2

        var frames: [String: PreviewFrame] = [:]
        for item in items {
            frames[item.id] = PreviewFrame(
                x: offsetX + (Double(item.rect.x) - minX) * scale,
                y: offsetY + (Double(item.rect.y) - minY) * scale,
                width: Double(item.rect.width) * scale,
                height: Double(item.rect.height) * scale
            )
        }
        return frames
    }
}
