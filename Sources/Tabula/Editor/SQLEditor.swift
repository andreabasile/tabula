import AppKit
import SwiftUI
import TabulaCore

struct SQLEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    var onRunCurrent: () -> Void
    var onRunAll: () -> Void
    var catalog: SchemaCatalog = SchemaCatalog()

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = SQLTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        let editor = SQLTextView(frame: textView.frame, textContainer: textView.textContainer)
        // init(frame:textContainer:) caps maxSize at the initial frame: without these the
        // editor never grows past one line and the text below cannot be scrolled to.
        editor.autoresizingMask = textView.autoresizingMask
        editor.minSize = textView.minSize
        editor.maxSize = textView.maxSize
        editor.isHorizontallyResizable = textView.isHorizontallyResizable
        editor.isVerticallyResizable = true
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.font = SQLHighlighter.font
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.delegate = context.coordinator
        editor.onRunCurrent = { context.coordinator.parent.onRunCurrent() }
        editor.onRunAll = { context.coordinator.parent.onRunAll() }
        editor.catalogProvider = { context.coordinator.parent.catalog }
        editor.string = text
        editor.backgroundColor = Theme.surfaceNS
        scrollView.documentView = editor
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.surfaceNS
        scrollView.verticalRulerView = LineNumberRuler(textView: editor)
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        SQLHighlighter.highlight(editor.textStorage)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scrollView.documentView as? NSTextView, editor.string != text else { return }
        editor.string = text
        SQLHighlighter.highlight(editor.textStorage)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLEditor

        init(_ parent: SQLEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? SQLTextView else { return }
            parent.text = editor.string
            SQLHighlighter.highlight(editor.textStorage)
            editor.updateCompletions(automatic: true)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.selection = editor.selectedRange()
        }
    }
}

final class SQLTextView: NSTextView {
    var onRunCurrent: (() -> Void)?
    var onRunAll: (() -> Void)?
    var catalogProvider: (() -> SchemaCatalog)?
    private let popup = CompletionPopup()
    private var replacementRange: Range<Int>?
    private var isInsertingCompletion = false

    /// Recomputes suggestions for the cursor. Automatic updates only open the list while a
    /// word or `alias.` is being typed, or right after JOIN; ⌃Space/Esc always open it.
    func updateCompletions(automatic: Bool) {
        guard !isInsertingCompletion, let catalog = catalogProvider?() else { return }
        let cursor = selectedRange().location
        let result = SQLCompleter.complete(text: string, cursor: cursor, catalog: catalog)
        let typedSomething = !result.replacementRange.isEmpty || precedingCharacter(at: cursor) == "."
        let wantsJoins = result.items.first?.kind == .join && precedingCharacter(at: cursor) == " "
        guard !automatic || popup.isVisible || typedSomething || wantsJoins,
              !result.items.isEmpty, let window else {
            popup.hide()
            return
        }
        if automatic, result.items.count == 1, result.items[0].insertText.caseInsensitiveCompare(currentWord(result.replacementRange)) == .orderedSame {
            popup.hide()
            return
        }
        replacementRange = result.replacementRange
        let caret = firstRect(forCharacterRange: NSRange(location: cursor, length: 0), actualRange: nil)
        popup.onAccept = { [weak self] item in self?.accept(item) }
        popup.show(result.items, below: NSPoint(x: caret.minX - 40, y: caret.minY), parent: window)
    }

    private func accept(_ item: CompletionItem) {
        guard let range = replacementRange else { return }
        isInsertingCompletion = true
        insertText(item.insertText, replacementRange: NSRange(location: range.lowerBound, length: range.count))
        isInsertingCompletion = false
        popup.hide()
    }

    private func precedingCharacter(at cursor: Int) -> Character? {
        guard cursor > 0 else { return nil }
        return (string as NSString).substring(with: NSRange(location: cursor - 1, length: 1)).first
    }

    private func currentWord(_ range: Range<Int>) -> String {
        (string as NSString).substring(with: NSRange(location: range.lowerBound, length: range.count))
    }

    override func resignFirstResponder() -> Bool {
        popup.hide()
        return super.resignFirstResponder()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let hint = "-- Scrivi la query qui. ⌘↩ esegue lo statement corrente, ⇧⌘↩ tutto.\n-- ⌃Spazio o Esc per i suggerimenti; dopo JOIN propone tabella e condizione ON." as NSString
        hint.draw(
            at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height),
            withAttributes: [.font: SQLHighlighter.font, .foregroundColor: NSColor.placeholderTextColor]
        )
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if handleCompletionKey(event, isReturn: isReturn, flags: flags) { return }
        if isReturn, flags == [.command] {
            onRunCurrent?()
            return
        }
        if isReturn, flags == [.command, .shift] {
            onRunAll?()
            return
        }
        super.keyDown(with: event)
    }

    private func handleCompletionKey(_ event: NSEvent, isReturn: Bool, flags: NSEvent.ModifierFlags) -> Bool {
        let isEscape = event.keyCode == 53
        let isControlSpace = event.keyCode == 49 && flags == [.control]
        guard popup.isVisible else {
            if isControlSpace || (isEscape && flags.isEmpty) {
                updateCompletions(automatic: false)
                return true
            }
            return false
        }
        switch event.keyCode {
        case 125: popup.moveSelection(by: 1)
        case 126: popup.moveSelection(by: -1)
        case 121: popup.moveSelection(by: 8)
        case 116: popup.moveSelection(by: -8)
        case 48: popup.acceptSelection()
        case 53: popup.hide()
        default:
            guard isReturn, flags.isEmpty else { return false }
            popup.acceptSelection()
        }
        return true
    }
}

@MainActor
enum SQLHighlighter {
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    private static let keywords = """
        select from where and or not in is null as on join left right inner outer full cross group by order \
        having limit offset insert into values update set delete create table view index drop alter add column \
        primary key foreign references default unique check constraint distinct union all except intersect case \
        when then else end begin commit rollback transaction with returning explain analyze show grant revoke \
        exists between like ilike asc desc true false schema if cascade async truncate
        """.split(separator: " ").map(String.init)

    private static let keywordPattern = try! NSRegularExpression(
        pattern: "\\b(" + keywords.joined(separator: "|") + ")\\b",
        options: [.caseInsensitive]
    )
    private static let stringPattern = try! NSRegularExpression(pattern: "'(?:[^']|'')*'?")
    private static let numberPattern = try! NSRegularExpression(pattern: "\\b\\d+(\\.\\d+)?\\b")
    private static let commentPattern = try! NSRegularExpression(pattern: "--[^\\n]*|/\\*[\\s\\S]*?(\\*/|$)")

    @MainActor
    static func highlight(_ storage: NSTextStorage?) {
        guard let storage else { return }
        let text = storage.string
        let whole = NSRange(location: 0, length: (text as NSString).length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: whole)
        apply(keywordPattern, color: .systemPink, in: storage, text: text, range: whole)
        apply(numberPattern, color: .systemPurple, in: storage, text: text, range: whole)
        apply(stringPattern, color: .systemRed, in: storage, text: text, range: whole)
        apply(commentPattern, color: .systemGray, in: storage, text: text, range: whole)
        storage.endEditing()
    }

    @MainActor
    private static func apply(_ pattern: NSRegularExpression, color: NSColor, in storage: NSTextStorage, text: String, range: NSRange) {
        for match in pattern.matches(in: text, range: range) {
            storage.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}
