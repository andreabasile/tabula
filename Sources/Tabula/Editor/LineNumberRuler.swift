import AppKit
import TabulaCore

/// The gutter with line numbers on the left of the SQL editor, as in TablePlus.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 38
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSText.didChangeNotification, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSView.boundsDidChangeNotification, object: textView.enclosingScrollView?.contentView)
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func refresh() {
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        let text = textView.string as NSString
        let visible = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let firstCharacter = layoutManager.characterIndexForGlyph(at: visible.location)
        var lineNumber = textView.string.utf16Units[..<firstCharacter].lazy.filter { $0 == 0x0A }.count + 1
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        let offset = convert(NSPoint.zero, from: textView).y + textView.textContainerInset.height
        var characterIndex = firstCharacter
        let end = NSMaxRange(layoutManager.characterRange(forGlyphRange: visible, actualGlyphRange: nil))
        repeat {
            let lineRange = text.lineRange(for: NSRange(location: characterIndex, length: 0))
            let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: lineRange.location, length: 0), actualCharacterRange: nil)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: min(glyphs.location, max(layoutManager.numberOfGlyphs - 1, 0)), effectiveRange: nil)
            let label = "\(lineNumber)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: offset + lineRect.minY + (lineRect.height - size.height) / 2), withAttributes: attributes)
            lineNumber += 1
            characterIndex = NSMaxRange(lineRange)
        } while characterIndex < end
        if text.length == 0 || text.hasSuffix("\n"), characterIndex >= text.length {
            let extra = layoutManager.extraLineFragmentRect
            if extra.height > 0 {
                let label = "\(lineNumber)" as NSString
                let size = label.size(withAttributes: attributes)
                label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: offset + extra.minY + (extra.height - size.height) / 2), withAttributes: attributes)
            }
        }
    }
}
