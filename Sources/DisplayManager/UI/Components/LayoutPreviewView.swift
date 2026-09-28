import DisplayManagerCore
import SwiftUI

/// Proportional drawing of a layout, similar to System Settings › Displays › Arrange. No screenshots.
struct LayoutPreviewView: View {
    let preview: PreviewModel
    var height: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                let frames = PreviewGeometry.frames(
                    for: preview.items, canvasWidth: geometry.size.width, canvasHeight: geometry.size.height, padding: 16)
                ZStack(alignment: .topLeading) {
                    ForEach(preview.items) { item in
                        if let frame = frames[item.id] {
                            // A small inset keeps a visible gap between adjacent displays.
                            let width = max(frame.width - 3, 4)
                            let height = max(frame.height - 3, 4)
                            DisplayTile(item: item, size: CGSize(width: width, height: height))
                                .frame(width: width, height: height)
                                .position(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
                        }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            }
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.5)))
            .overlay {
                if preview.items.isEmpty {
                    Text("No active displays").foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Layout preview")

            if !preview.disabledNames.isEmpty {
                HStack(spacing: 6) {
                    Text("Disabled:").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(preview.disabledNames.enumerated()), id: \.offset) { _, name in
                        Text(name)
                            .font(.caption)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.quaternary))
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct DisplayTile: View {
    let item: PreviewItem
    let size: CGSize

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 6, style: .continuous) }

    var body: some View {
        ZStack {
            shape.fill(item.isConnected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.06))
            shape.strokeBorder(
                item.isConnected ? Color.accentColor.opacity(0.75) : Color.secondary,
                style: StrokeStyle(lineWidth: 1.5, dash: item.isConnected ? [] : [5, 3]))

            if item.isMain {
                VStack {
                    Rectangle()
                        .fill(Color.primary.opacity(0.28))
                        .frame(height: max(3, min(8, size.height * 0.06)))
                    Spacer(minLength: 0)
                }
                .clipShape(shape)
            }

            labels.padding(6)

            if item.rotation != 0, size.width > 44, size.height > 30 {
                VStack {
                    HStack {
                        Spacer()
                        Text("\(item.rotation)°")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 4)
                            .background(Capsule().fill(.background.opacity(0.8)))
                    }
                    Spacer()
                }
                .padding(.top, item.isMain ? 10 : 4)
                .padding(.trailing, 4)
            }
        }
        .help(accessibilityText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var labels: some View {
        let showName = size.width > 40 && size.height > 22
        let showResolution = size.height > 44 && size.width > 70
        let showRate = size.height > 62 && size.width > 70
        VStack(spacing: 2) {
            if !item.isConnected, size.height > 30 {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if showName {
                if item.isMirrored {
                    Text("Mirrored").font(.caption.weight(.semibold))
                    if showResolution {
                        Text(item.names.joined(separator: " + ")).font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Text(item.names.first ?? "Display").font(.caption.weight(.semibold))
                }
            }
            if showResolution, let resolution = item.resolution {
                Text("\(resolution.width) × \(resolution.height)").font(.caption2).monospacedDigit()
            }
            if showRate, let refreshRate = item.refreshRate {
                Text("\(refreshRate) Hz").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .minimumScaleFactor(0.7)
    }

    private var accessibilityText: String {
        var parts = [item.isMirrored ? "Mirrored: \(item.names.joined(separator: " and "))" : (item.names.first ?? "Display")]
        if let resolution = item.resolution { parts.append("\(resolution.width) by \(resolution.height)") }
        if let refreshRate = item.refreshRate { parts.append("\(refreshRate) hertz") }
        if item.isMain { parts.append("main display") }
        if item.rotation != 0 { parts.append("rotated \(item.rotation) degrees") }
        if !item.isConnected { parts.append("not connected") }
        return parts.joined(separator: ", ")
    }
}
