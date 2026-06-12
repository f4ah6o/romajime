@preconcurrency import AppKit
import InputMethodKit
import RomajimeCore

final class JumpOverlayController {
    private var panel: NSPanel?
    private weak var overlayView: JumpOverlayView?

    func show(targets: [JumpTarget], client: any IMKTextInput) {
        let items = overlayItems(for: targets, client: client)
        guard !items.isEmpty else {
            hide()
            return
        }

        let contentFrame = items
            .map(\.frame)
            .reduce(NSRect.null) { $0.union($1) }
            .insetBy(dx: -6, dy: -6)
        guard !contentFrame.isNull, contentFrame.width > 0, contentFrame.height > 0 else {
            hide()
            return
        }

        let viewItems = items.map { item in
            JumpOverlayItem(
                index: item.index,
                primaryLabel: item.primaryLabel,
                numericLabel: item.numericLabel,
                frame: item.frame.offsetBy(dx: -contentFrame.minX, dy: -contentFrame.minY)
            )
        }
        let view = JumpOverlayView(frame: NSRect(origin: .zero, size: contentFrame.size))
        view.items = viewItems

        let panel = NSPanel(
            contentRect: contentFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = view
        panel.orderFrontRegardless()

        hide()
        self.panel = panel
        overlayView = view
    }

    func update(activePrefix: String) {
        overlayView?.activePrefix = activePrefix
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        overlayView = nil
    }

    private func overlayItems(for targets: [JumpTarget], client: any IMKTextInput) -> [JumpOverlayItem] {
        targets.enumerated().compactMap { index, target in
            let characterRange = NSRange(location: target.range.location, length: min(target.range.length, 1))
            var actualRange = NSRange(location: NSNotFound, length: 0)
            let characterRect = client.firstRect(forCharacterRange: characterRange, actualRange: &actualRange)
            guard characterRect.isUsableTextRect else {
                return nil
            }

            let primaryLabel = JumpLabelGenerator.label(for: index)
            let numericLabel = JumpLabelGenerator.numericLabel(for: index)
            let badgeSize = JumpOverlayView.badgeSize(primaryLabel: primaryLabel, numericLabel: numericLabel)
            let x = characterRect.minX
            let y = characterRect.maxY + 2
            return JumpOverlayItem(
                index: index,
                primaryLabel: primaryLabel,
                numericLabel: numericLabel,
                frame: NSRect(origin: NSPoint(x: x, y: y), size: badgeSize)
            )
        }
    }
}

private struct JumpOverlayItem {
    var index: Int
    var primaryLabel: String
    var numericLabel: String
    var frame: NSRect

    func matches(prefix: String) -> Bool {
        prefix.isEmpty || primaryLabel.hasPrefix(prefix) || numericLabel.hasPrefix(prefix)
    }
}

private final class JumpOverlayView: NSView {
    var items: [JumpOverlayItem] = [] {
        didSet {
            needsDisplay = true
        }
    }
    var activePrefix = "" {
        didSet {
            needsDisplay = true
        }
    }

    override var isFlipped: Bool {
        false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        for item in items {
            let isActive = item.matches(prefix: activePrefix)
            drawBadge(item, isActive: isActive)
        }
    }

    static func badgeSize(primaryLabel: String, numericLabel: String) -> NSSize {
        let text = "\(primaryLabel) \(numericLabel)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        return NSSize(width: ceil(textSize.width) + 14, height: 20)
    }

    private func drawBadge(_ item: JumpOverlayItem, isActive: Bool) {
        let background = isActive
            ? NSColor.systemBlue.withAlphaComponent(0.92)
            : NSColor.controlBackgroundColor.withAlphaComponent(0.84)
        let stroke = isActive
            ? NSColor.white.withAlphaComponent(0.65)
            : NSColor.systemBlue.withAlphaComponent(0.45)
        let foreground = isActive ? NSColor.white : NSColor.labelColor
        let secondary = isActive
            ? NSColor.white.withAlphaComponent(0.78)
            : NSColor.secondaryLabelColor.withAlphaComponent(0.9)

        let path = NSBezierPath(roundedRect: item.frame, xRadius: 5, yRadius: 5)
        background.setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = 1
        path.stroke()

        let primaryAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
            .foregroundColor: foreground
        ]
        let numericAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: secondary
        ]

        let primary = item.primaryLabel as NSString
        let numeric = item.numericLabel as NSString
        let primarySize = primary.size(withAttributes: primaryAttributes)
        let numericSize = numeric.size(withAttributes: numericAttributes)
        let baselineY = item.frame.midY - max(primarySize.height, numericSize.height) / 2
        primary.draw(
            at: NSPoint(x: item.frame.minX + 7, y: baselineY),
            withAttributes: primaryAttributes
        )
        numeric.draw(
            at: NSPoint(x: item.frame.minX + 9 + primarySize.width, y: baselineY + 1),
            withAttributes: numericAttributes
        )
    }
}

private extension NSRect {
    var isUsableTextRect: Bool {
        !isNull && !isInfinite && origin.x.isFinite && origin.y.isFinite && width.isFinite && height.isFinite
    }
}
