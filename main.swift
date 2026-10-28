import Cocoa

// MARK: - Palette (dark / light, resolved at draw time)

func dyn(_ dark: UInt32, _ light: UInt32) -> NSColor {
    func c(_ h: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((h >> 16) & 0xff) / 255, green: CGFloat((h >> 8) & 0xff) / 255,
                blue: CGFloat(h & 0xff) / 255, alpha: 1)
    }
    return NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? c(dark) : c(light) }
}

enum P {
    static let bg = dyn(0x0e0f11, 0xf2f3f3), surface = dyn(0x17191c, 0xffffff), raise = dyn(0x1d2024, 0xffffff)
    static let ink = dyn(0xecedef, 0x15171b), ink2 = dyn(0x9a9ea7, 0x565b63), faint = dyn(0x6a6f77, 0x8a8f98)
    static let line = dyn(0x292c31, 0xe1e3e5), line2 = dyn(0x212429, 0xeceef0)
    static let accent = dyn(0xff5346, 0xdc2d21), accentText = dyn(0xff6a5f, 0xbe261c)
    static let onAccent = dyn(0x0e0f11, 0xffffff), trackOff = dyn(0x3a3e44, 0xc9ccd0)
}

let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

// MARK: - Backend client (the proxy's /api/mappings)

struct APIError: LocalizedError { let message: String; var errorDescription: String? { message } }

final class Store {
    private let url = URL(string: "http://127.0.0.1:\(Config.port)/api/mappings")!

    func request(_ method: String, body: [String: String]? = nil, done: @escaping (Result<[Mapping], Error>) -> Void) {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        r.httpMethod = method
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "content-type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        URLSession.shared.dataTask(with: r) { data, resp, err in
            let result: Result<[Mapping], Error>
            if let err {
                result = .failure(err)
            } else if let data, let http = resp as? HTTPURLResponse {
                if http.statusCode == 200, let m = try? JSONDecoder().decode([Mapping].self, from: data) {
                    result = .success(m)
                } else {
                    let msg = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
                    result = .failure(APIError(message: msg ?? "Request failed"))
                }
            } else {
                result = .failure(APIError(message: "No response from the proxy"))
            }
            DispatchQueue.main.async { done(result) }
        }.resume()
    }
}

// MARK: - Custom controls

/// Title-bar proxy control from the design canvas: dot + "Proxy on/off" + switch in one 28 px pill.
/// Fixed width so the pill never resizes between states; state shows in dot, label and track.
final class ProxyPill: NSView {
    var on = false { didSet { needsDisplay = true } }
    var onToggle: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 130, height: 28))
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel("Route browser traffic through the proxy")
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 130, height: 28) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onToggle?() }
    override func accessibilityPerformPress() -> Bool { onToggle?(); return true }
    override func accessibilityValue() -> Any? { on ? 1 : 0 }

    override func draw(_ dirty: NSRect) {
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        P.surface.setFill(); pill.fill()
        P.line.setStroke(); pill.lineWidth = 1; pill.stroke()

        (on ? P.accent : P.faint).setFill()
        NSBezierPath(ovalIn: NSRect(x: 12, y: bounds.midY - 3.5, width: 7, height: 7)).fill()

        let text = on ? "Proxy on" : "Proxy off"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: on ? P.ink : P.ink2,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: 26, y: bounds.midY - size.height / 2), withAttributes: attrs)

        let track = NSRect(x: bounds.width - 4 - 34, y: bounds.midY - 10, width: 34, height: 20)
        (on ? P.accent : P.trackOff).setFill()
        NSBezierPath(roundedRect: track, xRadius: 10, yRadius: 10).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: track.minX + (on ? 16 : 2), y: track.minY + 2, width: 16, height: 16)).fill()
    }
}

/// Small filled circle (status dots).
final class DotView: NSView {
    var color: NSColor = P.accent { didSet { needsDisplay = true } }
    var diameter: CGFloat = 7
    override var intrinsicContentSize: NSSize { NSSize(width: diameter, height: diameter) }
    override func draw(_ dirty: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// Rounded surface with a hairline border; hosts the rewrites list.
final class CardView: NSView {
    override func draw(_ dirty: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 13, yRadius: 13)
        P.surface.setFill(); path.fill()
        P.line.setStroke(); path.lineWidth = 1; path.stroke()
    }
}

/// Footer with a hairline on top.
final class FooterView: NSView {
    override func draw(_ dirty: NSRect) {
        P.line2.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }
}

/// Text field that reports focus changes so its shell can draw the accent border.
final class URLField: NSTextField {
    var onFocus: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?(true) }
        return ok
    }
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocus?(false)
    }
}

/// Raised, bordered input (from the design canvas): hairline border, accent border + glow while focused.
final class FieldShell: NSView {
    let field = URLField()

    /// True only while this field's editor really is the first responder of the key window, so the
    /// border can never get out of sync with where typing would go.
    private var focused: Bool {
        guard let w = window, w.isKeyWindow, let editor = w.firstResponder as? NSTextView else { return false }
        return editor.isFieldEditor && editor.delegate === field
    }

    init(placeholder: String) {
        super.init(frame: .zero)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = mono
        field.textColor = P.ink
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.lineBreakMode = .byClipping
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: mono, .foregroundColor: P.faint,
        ])
        field.onFocus = { [weak self] _ in self?.needsDisplay = true }
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 40) }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(field) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let w = window else { return }
        for n in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { [weak self] _ in
                self?.needsDisplay = true
            }
        }
    }

    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 2, dy: 2)
        if focused {
            P.accent.withAlphaComponent(0.22).setStroke()
            let glow = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9)
            glow.lineWidth = 5; glow.stroke()
        }
        let path = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9)
        P.raise.setFill(); path.fill()
        (focused ? P.accent : P.line).setStroke()
        path.lineWidth = 1; path.stroke()
    }
}

/// Primary accent button, 40 px tall to match the fields.
final class AccentButton: NSButton {
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        wantsLayer = true
        setButtonType(.momentaryChange)
        imagePosition = .imageLeading
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: super.intrinsicContentSize.width + 36, height: 40) }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = P.accent.withAlphaComponent(isHighlighted ? 0.82 : 1).cgColor
        }
        layer?.cornerRadius = 9
    }
}

// MARK: - Table cell

final class RewriteCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("rewrite")
    private let from = NSTextField(labelWithString: "")
    private let to = NSTextField(labelWithString: "")
    private let kind = NSTextField(labelWithString: "")
    private let remove = NSButton()
    private var armed = false
    private var timer: Timer?
    var onRemove: (() -> Void)?
    var showSeparator = true { didSet { needsDisplay = true } }

    override func draw(_ dirty: NSRect) {
        guard showSeparator else { return }
        P.line2.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.id

        for l in [from, to] {
            l.font = mono
            l.lineBreakMode = .byTruncatingMiddle
            l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        from.textColor = P.ink
        to.textColor = P.accentText

        remove.isBordered = false
        remove.target = self
        remove.action = #selector(tapRemove)
        remove.setContentHuggingPriority(.required, for: .horizontal)
        remove.setAccessibilityLabel("Remove rewrite")
        showRemove(armed: false)

        let texts = NSStackView(views: [from, to, kind])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        texts.setCustomSpacing(7, after: to)
        texts.translatesAutoresizingMaskIntoConstraints = false
        remove.translatesAutoresizingMaskIntoConstraints = false
        addSubview(texts); addSubview(remove)
        NSLayoutConstraint.activate([
            texts.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            texts.centerYAnchor.constraint(equalTo: centerYAnchor),
            texts.trailingAnchor.constraint(lessThanOrEqualTo: remove.leadingAnchor, constant: -12),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            remove.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        timer?.invalidate(); armed = false; showRemove(armed: false)
    }

    func configure(_ m: Mapping) {
        let prefix = m.from.hasSuffix("*")
        from.stringValue = m.from; from.toolTip = m.from
        to.stringValue = "→ " + m.to; to.toolTip = m.to
        let s = NSMutableAttributedString(string: "●  ", attributes: [
            .font: NSFont.systemFont(ofSize: 7), .foregroundColor: prefix ? P.accent : P.faint,
            .baselineOffset: 1,
        ])
        s.append(NSAttributedString(string: prefix ? "WHOLE PATH" : "EXACT MATCH", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: P.ink2, .kern: 1.0,
        ]))
        kind.attributedStringValue = s
    }

    private func showRemove(armed: Bool) {
        remove.attributedTitle = NSAttributedString(string: armed ? "Confirm" : "Remove", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: armed ? .bold : .medium),
            .foregroundColor: armed ? P.accentText : P.ink2,
        ])
    }

    @objc private func tapRemove() {
        if armed { timer?.invalidate(); onRemove?(); return }
        armed = true
        showRemove(armed: true)
        // Two-step delete: the second click within 3 s confirms.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            self?.armed = false; self?.showRemove(armed: false)
        }
    }
}

// MARK: - Main screen

final class MainViewController: NSViewController, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let store = Store()
    private var mappings: [Mapping] = []

    private let fromShell = FieldShell(placeholder: "https://example.com/app.js")
    private let toShell = FieldShell(placeholder: "http://localhost:3000/app.js")
    private var fromField: URLField { fromShell.field }
    private var toField: URLField { toShell.field }
    private let addButton = AccentButton()
    private let column = NSLayoutGuide()
    private lazy var columnLeading = column.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24)
    private lazy var columnTrailing = column.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)
    private let reloadHint = NSTextField(labelWithString: "Still seeing old content? Hard-reload with ⌘⇧R")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let empty = NSStackView()
    private let footDot = DotView()
    private let footText = NSTextField(labelWithString: "")

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 620))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        build()
        setProxyState(false)
        load()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Always start in Replace, and tab Replace -> With -> Replace.
        fromField.nextKeyView = toField
        toField.nextKeyView = fromField
        view.window?.initialFirstResponder = fromField
        view.window?.makeFirstResponder(fromField)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        reloadHint.isHidden = view.bounds.width < 720   // not enough room next to the status text
        let inset = max(24, (view.bounds.width - 880) / 2)
        if columnLeading.constant != inset { columnLeading.constant = inset; columnTrailing.constant = -inset }
    }

    // MARK: layout

    private func caption(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: P.ink2, .kern: 1.4,
        ])
        l.alignment = .left
        return l
    }

    private func group(_ title: String, _ shell: FieldShell) -> NSStackView {
        let field = shell.field
        field.delegate = self
        field.target = self
        field.action = #selector(add)
        field.setAccessibilityLabel(title)
        let s = NSStackView(views: [caption(title), shell])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 6
        shell.translatesAutoresizingMaskIntoConstraints = false
        shell.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
        return s
    }

    private func build() {
        let g1 = group("Replace", fromShell)
        let g2 = group("With", toShell)

        addButton.target = self
        addButton.action = #selector(add)
        addButton.attributedTitle = NSAttributedString(string: "+  Add rewrite", attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: P.onAccent,
        ])

        let form = NSStackView(views: [g1, g2, addButton])
        form.orientation = .horizontal
        form.alignment = .bottom
        form.spacing = 12
        g1.widthAnchor.constraint(equalTo: g2.widthAnchor).isActive = true
        for g in [g1, g2] { g.setContentHuggingPriority(.init(1), for: .horizontal) }
        form.distribution = .fill

        let tip = NSTextField(wrappingLabelWithString: "")
        let t = NSMutableAttributedString(string: "End the first URL with ", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: P.ink2,
        ])
        t.append(NSAttributedString(string: "*", attributes: [.font: mono, .foregroundColor: P.accentText]))
        t.append(NSAttributedString(string: " to map a whole path.", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: P.ink2,
        ]))
        tip.attributedStringValue = t
        tip.alignment = .left

        errorLabel.font = .systemFont(ofSize: 13)
        errorLabel.textColor = P.accentText
        errorLabel.isHidden = true

        let top = NSStackView(views: [form, tip, errorLabel])
        top.orientation = .vertical
        top.alignment = .leading
        top.spacing = 10
        for v in [form, tip, errorLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true
        }

        let title = NSTextField(labelWithString: "Rewrites")
        title.font = .systemFont(ofSize: 19, weight: .bold)
        title.textColor = P.ink
        countLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        countLabel.textColor = P.ink2
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let head = NSStackView(views: [title, spacer, countLabel])
        head.orientation = .horizontal
        head.alignment = .lastBaseline

        // List
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .fullWidth
        table.backgroundColor = .clear
        table.rowHeight = 80
        table.intercellSpacing = .zero
        table.gridStyleMask = []
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 12
        scroll.layer?.masksToBounds = true

        let card = CardView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(scroll)

        let bigL = NSTextField(labelWithString: "No rewrites yet.")
        bigL.font = .systemFont(ofSize: 16, weight: .semibold)
        bigL.textColor = P.ink
        let hint = NSTextField(labelWithString: "Add a pair above. Changes apply right away.")
        hint.font = .systemFont(ofSize: 13)
        hint.textColor = P.ink2
        let ex = NSTextField(labelWithString: "Try https://example.com/*  to  http://localhost:3000/")
        ex.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        ex.textColor = P.faint
        empty.setViews([bigL, hint, ex], in: .leading)
        empty.orientation = .vertical
        empty.alignment = .centerX
        empty.spacing = 6
        empty.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(empty)

        // Footer
        let footer = FooterView()
        footText.font = .systemFont(ofSize: 12)
        footText.textColor = P.ink2
        footText.lineBreakMode = .byTruncatingTail
        footText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let reload = reloadHint
        reload.font = .systemFont(ofSize: 12)
        reload.textColor = P.ink2
        reload.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let left = NSStackView(views: [footDot, footText])
        left.orientation = .horizontal
        left.spacing = 8
        let fs = NSView()
        let foot = NSStackView(views: [left, fs, reload])
        foot.orientation = .horizontal
        foot.alignment = .centerY
        foot.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(foot)

        for v in [top, head, card, footer] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        // Content column: a centered column at most 880 pt wide. Done with a side margin that viewDidLayout
        // recomputes (not width inequalities, which AppKit would turn into a maximum window size).
        view.addLayoutGuide(column)
        NSLayoutConstraint.activate([
            columnLeading, columnTrailing,
            top.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            top.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: column.trailingAnchor),

            head.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 24),
            head.leadingAnchor.constraint(equalTo: top.leadingAnchor, constant: 1),
            head.trailingAnchor.constraint(equalTo: top.trailingAnchor, constant: -1),

            card.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 10),
            card.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -14),

            scroll.topAnchor.constraint(equalTo: card.topAnchor, constant: 1),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -1),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -1),
            empty.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: card.centerYAnchor),

            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 34),
            foot.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            foot.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            foot.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
    }

    // MARK: data

    private func apply(_ m: [Mapping]) {
        mappings = m
        table.reloadData()
        countLabel.stringValue = m.isEmpty ? "" : "\(m.count)"
        empty.isHidden = !m.isEmpty
    }

    /// Re-read the rewrites (e.g. after the CLI changed them while the app was in the background).
    func refresh() { load() }

    /// The server may still be binding its port right after launch, so retry the first load.
    private func load(attempt: Int = 0) {
        store.request("GET") { [weak self] r in
            guard let self else { return }
            switch r {
            case .success(let m): self.apply(m)
            case .failure(let e):
                if attempt < 25 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.load(attempt: attempt + 1) }
                } else {
                    self.showError("Can't reach the proxy: \(e.localizedDescription)")
                }
            }
        }
    }

    @objc private func add() {
        clearError()
        let f = fromField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = toField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !f.isEmpty, !t.isEmpty else { showError("Both URLs are required."); return }
        store.request("POST", body: ["from": f, "to": t]) { [weak self] r in
            guard let self else { return }
            switch r {
            case .success(let m):
                self.apply(m)
                self.fromField.stringValue = ""
                self.toField.stringValue = ""
                self.view.window?.makeFirstResponder(self.fromField)
            case .failure(let e): self.showError(e.localizedDescription)
            }
        }
    }

    private func remove(_ m: Mapping) {
        store.request("DELETE", body: ["from": m.from]) { [weak self] r in
            switch r {
            case .success(let list): self?.apply(list)
            case .failure(let e): self?.showError(e.localizedDescription)
            }
        }
    }

    private func showError(_ msg: String) { errorLabel.stringValue = msg; errorLabel.isHidden = false }
    private func clearError() { errorLabel.isHidden = true }
    func controlTextDidChange(_ obj: Notification) { clearError() }

    func setProxyState(_ on: Bool) {
        footDot.color = on ? P.accent : P.faint
        footText.stringValue = on ? "Routing browser traffic through 127.0.0.1:\(Config.port)"
                                  : "Proxy off. Rewrites are saved but not applied."
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { mappings.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: RewriteCell.id, owner: nil) as? RewriteCell
            ?? RewriteCell(frame: .zero)
        let m = mappings[row]
        cell.configure(m)
        cell.showSeparator = row < mappings.count - 1
        cell.onRemove = { [weak self] in self?.remove(m) }
        return cell
    }
}

// MARK: - App

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var main: MainViewController!
    var proxyServer: ProxyServer?
    var service = "Wi-Fi"
    var proxyOn = false
    var toggle: ProxyPill!
    let res = Config.resources

    func applicationDidFinishLaunching(_ note: Notification) {
        try? FileManager.default.createDirectory(atPath: Config.support, withIntermediateDirectories: true)

        // Free the port from any stale listener (e.g. an older, Node-based version), then run the proxy in this process.
        shell("/bin/bash", ["\(res)/proxyctl.sh", "claim"])
        let server = ProxyServer(store: MappingStore(path: Config.mappingsFile))
        do { try server.start() } catch { fail("Couldn't start the proxy on port \(Config.port): \(error.localizedDescription)"); return }
        proxyServer = server
        installCLI()

        service = shell("/bin/bash", ["\(res)/proxyctl.sh", "service"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if service.isEmpty { service = "Wi-Fi" }

        // Set the Dock icon explicitly so it never depends on macOS's (sticky) icon cache.
        if let icon = NSImage(contentsOfFile: "\(res)/AppIcon.icns") { NSApp.applicationIconImage = icon }

        buildMenu()
        buildWindow()
        setProxy(true)   // trusts the CA (admin prompt) + routes the browser through us
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Updater.checkInBackground() }
    }

    /// Puts the `switcheroo` command on the user's PATH (this binary, linked into a writable bin dir like
    /// Homebrew's). Silent, in the background, and it only ever replaces its own links.
    /// Opt out with: defaults write local.switcheroo InstallCLI -bool false
    func installCLI() {
        guard UserDefaults.standard.object(forKey: "InstallCLI") as? Bool ?? true else { return }
        DispatchQueue.global().async { try? CLI.install(quiet: true) }
    }

    func buildWindow() {
        main = MainViewController()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Switcheroo"
        window.contentViewController = main
        window.setContentSize(NSSize(width: 760, height: 620))
        window.minSize = NSSize(width: 560, height: 420)
        window.setFrameAutosaveName("MainWindow")   // remembers size/position across launches
        if !window.setFrameUsingName("MainWindow") { window.center() }
        // Blend the title bar into the content: same background (light/dark aware), no seam.
        window.titlebarAppearsTransparent = true
        window.backgroundColor = P.bg
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Proxy pill in the title bar, 20 px in from the window edge (per the design canvas).
        toggle = ProxyPill(frame: .zero)
        toggle.onToggle = { [weak self] in self?.flipProxy() }
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 150, height: 28))   // 130 pill + 20 right inset
        holder.addSubview(toggle)
        let acc = NSTitlebarAccessoryViewController()
        acc.view = holder
        acc.layoutAttribute = .right
        window.addTitlebarAccessoryViewController(acc)
    }

    private var switching = false
    private var lastFlip = Date.distantPast

    /// The `switcheroo` CLI can change rewrites and the system proxy behind the window's back,
    /// so re-read both whenever the app comes to the front.
    func applicationDidBecomeActive(_ note: Notification) {
        guard main != nil, !switching else { return }
        main.refresh()
        let actual = shell("/bin/bash", ["\(res)/proxyctl.sh", "status"]).trimmingCharacters(in: .whitespacesAndNewlines) == "on"
        if actual != proxyOn { proxyOn = actual; toggle.on = actual; main.setProxyState(actual) }
    }

    /// Process.waitUntilExit spins the run loop, so a second click can arrive while the first is still
    /// inside setProxy and would read stale state. Ignore clicks until the switch finishes, and treat a
    /// second click within 0.5 s (double-click) as part of the first.
    func flipProxy() {
        guard !switching, Date().timeIntervalSince(lastFlip) > 0.5 else { return }
        switching = true
        defer { switching = false; lastFlip = Date() }
        setProxy(!proxyOn)
    }

    func setProxy(_ on: Bool) {
        shell("/bin/bash", ["\(res)/proxyctl.sh", on ? "on" : "off"])
        proxyOn = on
        toggle.on = on
        main.setProxyState(on)
    }

    @objc func checkForUpdates() { Updater.check(silent: false) }

    func buildMenu() {
        let bar = NSMenu()
        func add(_ title: String, _ items: [(String, Selector, String)]) {
            let item = NSMenuItem(); bar.addItem(item)
            let m = NSMenu(title: title); item.submenu = m
            for (t, sel, key) in items { m.addItem(withTitle: t, action: sel, keyEquivalent: key) }
        }
        add("Switcheroo", [
            ("Check for Updates\u{2026}", #selector(checkForUpdates), ""),
            ("Quit Switcheroo", #selector(NSApplication.terminate(_:)), "q"),
        ])
        // Edit menu so Cmd+C / V / A / Z work in the URL fields.
        add("Edit", [
            ("Undo", Selector(("undo:")), "z"), ("Redo", Selector(("redo:")), "Z"),
            ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        NSApp.mainMenu = bar
    }

    func fail(_ msg: String) {
        let a = NSAlert()
        a.alertStyle = .critical
        a.messageText = "Switcheroo"
        a.informativeText = msg
        a.runModal()
        NSApp.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ note: Notification) {
        shell("/bin/bash", ["\(res)/proxyctl.sh", "off"])   // restore the user's proxy
        proxyServer?.stop()
    }
}

// `switcheroo <command>` (the CLI) runs the same binary without a window.
if CLI.requested(CommandLine.arguments) { exit(CLI.run(CommandLine.arguments)) }

let app = NSApplication.shared

// Quit cleanly (restoring the system proxy) on kill/Ctrl-C too, not only on Cmd+Q.
var quitSignals: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { NSApp.terminate(nil) }
    source.resume()
    quitSignals.append(source)
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
