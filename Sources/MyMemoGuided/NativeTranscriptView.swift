import SwiftUI
import AppKit
import MyMemoExperience

struct NativeTranscriptView: NSViewRepresentable {
    let document: TranscriptDocument
    var query: String = ""

    final class Coordinator {
        var documentID: UUID?
        var query = ""
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder; scroll.drawsBackground = false
        let text = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        text.isEditable = false; text.isSelectable = true; text.isRichText = false
        text.usesFindBar = true; text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        text.layoutManager?.allowsNonContiguousLayout = true
        text.textContainerInset = NSSize(width: 18, height: 18)
        text.drawsBackground = false
        text.setAccessibilityLabel("文字稿正文")
        scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        let changed = context.coordinator.documentID != document.id
        if changed {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 6
            text.textStorage?.setAttributedString(NSAttributedString(string: document.text, attributes: [
                .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]))
            context.coordinator.documentID = document.id
            text.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
        if changed || context.coordinator.query != query {
            context.coordinator.query = query
            let content = document.text as NSString
            text.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: content.length))
            var first: NSRange?
            for word in query.split(whereSeparator: \.isWhitespace).prefix(8) {
                var start = 0, count = 0
                while start < content.length && count < 500 {
                    let range = content.range(of: String(word), options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], range: NSRange(location: start, length: content.length - start))
                    if range.location == NSNotFound { break }
                    if first == nil { first = range }
                    text.layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3), forCharacterRange: range)
                    start = range.location + max(1, range.length); count += 1
                }
            }
            if let first { text.scrollRangeToVisible(first) }
        }
    }
}
