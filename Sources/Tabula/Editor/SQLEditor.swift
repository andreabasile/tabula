import AppKit
import SwiftUI

struct SQLEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    var onRunCurrent: () -> Void
    var onRunAll: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = SQLTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        let editor = SQLTextView(frame: textView.frame, textContainer: textView.textContainer)
        editor.autoresizingMask = textView.autoresizingMask
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
        editor.string = text
        scrollView.documentView = editor
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
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            SQLHighlighter.highlight(editor.textStorage)
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

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
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
