import AppKit
import TickerCore

/// The search seam (R148). A closure, so the picker can be built and tested
/// with no transport behind it.
typealias SymbolSearch = @Sendable (String) async throws -> [SearchResult]

/// Search-only, with a literal fallback. Built in code (R133).
@MainActor
final class SymbolPickerWindowController: NSWindowController,
                                          NSTableViewDataSource, NSTableViewDelegate,
                                          NSTextFieldDelegate {
    private let search: SymbolSearch
    private let onAdd: (Symbol) -> Void
    private var watchlist: [Symbol]

    private var session = SearchSession()
    private var debounce: Timer?
    private var model = SymbolPickerModel(rows: [], message: nil, isFull: false)

    private let field = NSTextField()
    private let table = NSTableView()
    private let messageLabel = NSTextField(labelWithString: "")
    private let addButton = NSButton(title: ErrorText.addButton, target: nil, action: nil)

    init(search: @escaping SymbolSearch,
         watchlist: [Symbol],
         onAdd: @escaping (Symbol) -> Void) {
        self.search = search
        self.watchlist = watchlist
        self.onAdd = onAdd

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = ErrorText.addSymbol
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = makeContentView()
        window.center()
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("R133: built in code, not a xib") }

    /// The watchlist changes under this window — Task 11's *Remove* is two
    /// clicks away in the dropdown — and the cap and the "already watching"
    /// marks both depend on it.
    func setWatchlist(_ symbols: [Symbol]) {
        watchlist = symbols
        rebuild(results: lastResults, error: lastError)
    }

    private var lastResults: [SearchResult] = []
    private var lastError: TickerError?

    // MARK: - Layout

    private func makeContentView() -> NSView {
        field.placeholderString = ErrorText.searchPlaceholder
        field.delegate = self

        table.headerView = nil
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row")))
        table.target = self
        table.doubleAction = #selector(addSelected)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        messageLabel.textColor = .secondaryLabelColor
        addButton.target = self
        addButton.action = #selector(addSelected)
        addButton.keyEquivalent = "\r"

        let footer = NSStackView(views: [messageLabel, NSView(), addButton])
        footer.orientation = .horizontal

        let stack = NSStackView(views: [field, scroll, footer])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Without this the scroll view collapses to its intrinsic height,
        // which for an empty table is zero.
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    // MARK: - Searching

    func controlTextDidChange(_ notification: Notification) {
        // R148: one search per pause in typing, not one per keystroke.
        debounce?.invalidate()
        let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.runSearch() }
        }
        debounce = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func runSearch() {
        let query = field.stringValue
        guard !query.isEmpty else {
            rebuild(results: [], error: nil)
            return
        }
        let generation = session.begin()
        Task { [weak self] in
            guard let self else { return }
            var found: [SearchResult] = []
            var failure: TickerError?
            do {
                found = try await self.search(query)
            } catch let error as TickerError {
                failure = error
            } catch {
                failure = .offline
            }
            // R148: the query may have moved on while this was in flight.
            guard self.session.accepts(generation) else { return }
            self.rebuild(results: found, error: failure)
        }
    }

    private func rebuild(results: [SearchResult], error: TickerError?) {
        lastResults = results
        lastError = error
        model = SymbolPickerModel.build(query: field.stringValue, results: results,
                                        error: error, watchlist: watchlist)
        render()
    }

    private func render() {
        table.reloadData()
        messageLabel.stringValue = model.message ?? ""
        addButton.isEnabled = addableSymbol() != nil
    }

    /// The symbol the Add button would add, or `nil` when there is nothing to
    /// add — no selection, the cap is reached, or it is already watched.
    private func addableSymbol() -> Symbol? {
        guard !model.isFull else { return nil }
        guard model.rows.indices.contains(table.selectedRow) else { return nil }
        switch model.rows[table.selectedRow] {
        case .result(let found, let isAdded):
            return isAdded ? nil : found.symbol
        case .literal(let symbol):
            return watchlist.contains(symbol) ? nil : symbol
        }
    }

    @objc private func addSelected() {
        guard let symbol = addableSymbol() else { return }
        onAdd(symbol)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { model.rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let text: String
        let dimmed: Bool
        switch model.rows[row] {
        case .result(let found, let isAdded):
            text = isAdded ? "\(ErrorText.searchRow(found)) — \(ErrorText.alreadyWatching)"
                           : ErrorText.searchRow(found)
            dimmed = isAdded
        case .literal(let symbol):
            // 15d: `addableSymbol()` already refuses an already-watched
            // literal (see its `.literal` arm below), so the row must say so
            // too — otherwise a symbol Yahoo's search index does not surface
            // (e.g. `^GSPC`) but that is already on the watchlist renders as
            // an ordinary, undimmed row whose Add button is inexplicably
            // disabled. R150's second half is "shown and marked, not filtered
            // out", not "shown and marked only when it came from search".
            let isAdded = watchlist.contains(symbol)
            text = isAdded ? "\(ErrorText.literalRow(symbol)) — \(ErrorText.alreadyWatching)"
                           : ErrorText.literalRow(symbol)
            dimmed = isAdded
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = dimmed ? .tertiaryLabelColor : .labelColor
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        addButton.isEnabled = addableSymbol() != nil
    }
}
