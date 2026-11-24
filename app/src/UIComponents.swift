import Cocoa

// MARK: - 自适应外观组件（切换深浅色时自动重设 CALayer 颜色）
class AdaptiveView: NSView {
    var fillColor: NSColor = .clear { didSet { applyColors() } }
    var onAppearanceChange: (() -> Void)?
    var strokeColor: NSColor = .clear { didSet { applyColors() } }
    var radius: CGFloat = 0 { didSet { layer?.cornerRadius = radius } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    func applyColors() {
        defer { onAppearanceChange?() }
        guard let layer = layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = self.fillColor.cgColor
            layer.borderColor = self.strokeColor.cgColor
            layer.borderWidth = self.strokeColor == .clear ? 0 : 1
            layer.cornerRadius = self.radius
        }
    }
}

final class PillButton: NSButton {
    var fill: NSColor = Theme.hover
    var labelColor: NSColor = .labelColor
    var fontForTitle: NSFont = .systemFont(ofSize: 12, weight: .medium)

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }
    func applyStyle() {
        wantsLayer = true
        layer?.cornerRadius = 7
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill.cgColor
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: fontForTitle,
                .foregroundColor: labelColor,
            ])
        }
    }
}

final class BorderedScrollView: NSScrollView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        wantsLayer = true
        layer?.cornerRadius = 8
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderWidth = 1
            layer?.borderColor = Theme.border.cgColor
        }
    }
}

final class CardView: AdaptiveView {
    init(fill: NSColor = Theme.cardBG, radius: CGFloat = 10, bordered: Bool = true) {
        super.init(frame: .zero)
        self.fillColor = fill
        self.radius = radius
        self.strokeColor = bordered ? Theme.border : .clear
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class ServerRowView: NSView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let subLabel = NSTextField(labelWithString: "")
    private let dot = NSView()
    var onSelect: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        subLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subLabel.textColor = .secondaryLabelColor
        subLabel.lineBreakMode = .byTruncatingTail
        for v in [dot, nameLabel, subLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 46),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            nameLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            subLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            subLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            subLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private var selectedState = false
    private var healthyState = false

    func configure(name: String, sub: String, selected: Bool, healthy: Bool) {
        nameLabel.stringValue = name
        subLabel.stringValue = sub
        selectedState = selected
        healthyState = healthy
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        wantsLayer = true
        layer?.cornerRadius = 8
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (selectedState ? Theme.rowSelected : NSColor.clear).cgColor
            dot.layer?.backgroundColor = (healthyState ? Theme.accent : NSColor.tertiaryLabelColor).cgColor
        }
    }
    override func mouseDown(with event: NSEvent) { onSelect?() }
}
