import AppKit

/// The completion list window: a borderless, non-activating child panel of
/// the editor's window, plus a second panel beside it for the selected item's
/// documentation.
///
/// Non-activating and never key, so the text view keeps keyboard focus and
/// the caret keeps blinking; all keys reach `CompletionController` through the
/// text view. The panel only renders a `CompletionListModel` and reports
/// clicks back — it holds no state of its own.
@MainActor
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /// Single click on a row.
    var onSelect: ((Int) -> Void)?
    /// Double click on a row.
    var onAccept: ((Int) -> Void)?

    static let maxVisibleRows = 10

    private let panel: NSPanel
    private let docPanel: NSPanel
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let docField = NSTextField(wrappingLabelWithString: "")
    private var entries: [CompletionListModel.Entry] = []
    private var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    /// Suppresses `onSelect` while the selection is being set from the model.
    private var isUpdatingSelection = false

    /// Horizontal distance from the panel's left edge to the label text, so
    /// the labels line up with the text being completed.
    private let labelInset: CGFloat = 30
    private let docWidth: CGFloat = 300

    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = Self.makePanel()
        docPanel = Self.makePanel()
        super.init()

        let column = NSTableColumn(identifier: .init("item"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.rowSizeStyle = .custom
        tableView.refusesFirstResponder = true
        tableView.allowsEmptySelection = false
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked(_:))
        tableView.doubleAction = #selector(rowDoubleClicked(_:))

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(scrollView)

        docField.isSelectable = false
        docField.textColor = .secondaryLabelColor
        docField.autoresizingMask = [.width, .height]
        docPanel.contentView?.addSubview(docField)
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.masksToBounds = true
        panel.contentView = background
        return panel
    }

    // MARK: Showing

    /// Shows or updates the list for `model`, positioned below `caretRect`
    /// (screen coordinates), or above it when there is no room below.
    func show(_ model: CompletionListModel, caretRect: NSRect, parent: NSWindow, font: NSFont) {
        self.font = NSFont(descriptor: font.fontDescriptor, size: max(11, font.pointSize - 1)) ?? font
        entries = model.entries
        tableView.rowHeight = ceil(self.font.boundingRectForFont.height) + 6
        tableView.reloadData()

        let rows = min(entries.count, Self.maxVisibleRows)
        let height = CGFloat(rows) * tableView.rowHeight + 8
        let width = listWidth()
        let screen = (parent.screen ?? NSScreen.main)?.visibleFrame ?? .infinite

        var origin = NSPoint(x: caretRect.minX - labelInset, y: caretRect.minY - height - 2)
        if origin.y < screen.minY { origin.y = caretRect.maxY + 2 }
        origin.x = max(screen.minX, min(origin.x, screen.maxX - width))
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        scrollView.frame = panel.contentView!.bounds.insetBy(dx: 0, dy: 4)
        tableView.tableColumns.first?.width = scrollView.contentSize.width

        panel.appearance = parent.effectiveAppearance
        docPanel.appearance = parent.effectiveAppearance
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        updateSelection(model.selectedIndex)
    }

    func updateSelection(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        isUpdatingSelection = true
        tableView.selectRowIndexes([index], byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
        isUpdatingSelection = false
        showDocumentation(for: entries[index].item)
    }

    func hide() {
        for window in [docPanel, panel] {
            window.parent?.removeChildWindow(window)
            window.orderOut(nil)
        }
    }

    private func listWidth() -> CGFloat {
        let labelFont = font
        let detailFont = NSFont.systemFont(ofSize: max(10, font.pointSize - 2))
        var widest: CGFloat = 0
        for entry in entries.prefix(200) {
            let label = (entry.item.label as NSString).size(withAttributes: [.font: labelFont]).width
            let detail = entry.item.detail.isEmpty ? 0 : (entry.item.detail as NSString).size(withAttributes: [.font: detailFont]).width + 16
            widest = max(widest, label + detail)
        }
        return min(560, max(220, ceil(widest) + labelInset + 24))
    }

    private func showDocumentation(for item: CompletionItem) {
        guard !item.documentation.isEmpty, panel.isVisible, let parent = panel.parent else {
            docPanel.parent?.removeChildWindow(docPanel)
            docPanel.orderOut(nil)
            return
        }
        docField.font = .systemFont(ofSize: max(11, font.pointSize - 1))
        docField.stringValue = item.documentation
        let inner = docWidth - 20
        let textHeight = min(320, ceil(docField.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 10_000)).height ?? 40))
        let height = textHeight + 16
        let list = panel.frame
        let screen = (parent.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
        var x = list.maxX + 4
        if x + docWidth > screen.maxX { x = list.minX - docWidth - 4 }
        let frame = NSRect(x: x, y: list.maxY - height, width: docWidth, height: height)
        docPanel.setFrame(frame, display: true)
        docField.frame = NSRect(x: 10, y: 8, width: inner, height: textHeight)
        if docPanel.parent !== parent {
            docPanel.parent?.removeChildWindow(docPanel)
            parent.addChildWindow(docPanel, ordered: .above)
        }
        docPanel.orderFront(nil)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: CompletionCellView.identifier, owner: nil) as? CompletionCellView)
            ?? CompletionCellView()
        cell.configure(with: entries[row], font: font)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdatingSelection, tableView.selectedRow >= 0 else { return }
        onSelect?(tableView.selectedRow)
    }

    @objc private func rowClicked(_ sender: Any?) {
        guard tableView.clickedRow >= 0 else { return }
        onSelect?(tableView.clickedRow)
    }

    @objc private func rowDoubleClicked(_ sender: Any?) {
        guard tableView.clickedRow >= 0 else { return }
        onAccept?(tableView.clickedRow)
    }
}

/// One row: kind icon, label with the matched characters in bold, and the
/// detail right-aligned in grey.
@MainActor
final class CompletionCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("CompletionCell")

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        for view in [icon, label, detail] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = icon
        textField = label
        icon.contentTintColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        detail.lineBreakMode = .byTruncatingTail
        detail.alignment = .right
        detail.textColor = .secondaryLabelColor
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            detail.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(with entry: CompletionListModel.Entry, font: NSFont) {
        icon.image = NSImage(systemSymbolName: entry.item.kind.systemImage, accessibilityDescription: nil)
        label.attributedStringValue = Self.highlighted(entry.item.label, matches: entry.labelHighlights, font: font)
        detail.font = .systemFont(ofSize: max(10, font.pointSize - 2))
        detail.stringValue = entry.item.detail
    }

    /// The label with matched characters bold, everything else regular.
    static func highlighted(_ label: String, matches: [Int], font: NSFont) -> NSAttributedString {
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let result = NSMutableAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let matched = Set(matches)
        var utf16Offset = 0
        for (index, character) in label.enumerated() {
            let length = character.utf16.count
            if matched.contains(index) {
                result.addAttribute(.font, value: bold, range: NSRange(location: utf16Offset, length: length))
            }
            utf16Offset += length
        }
        return result
    }
}
