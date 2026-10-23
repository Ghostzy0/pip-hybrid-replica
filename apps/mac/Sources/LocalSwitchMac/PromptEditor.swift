import AppKit
import SwiftUI

/// Native multiline editing with ordinary selection, undo and IME behavior.
/// The composer owns a bounded scroll region without an always-visible empty scroller gutter.
struct PromptEditor: NSViewRepresentable {
  @Binding var text: String
  @Binding var wantsFocus: Bool
  var inputLabel = "Message to local model"
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = false
    scroll.hasHorizontalScroller = false
    scroll.borderType = .noBorder
    let editor = NSTextView(frame: .zero)
    editor.isRichText = false
    editor.importsGraphics = false
    editor.allowsUndo = true
    editor.drawsBackground = false
    editor.font =
      NSFont(name: "Geist-Regular", size: 14 * PipMetrics.textScale)
      ?? .systemFont(ofSize: 14 * PipMetrics.textScale)
    editor.textColor = .labelColor
    editor.insertionPointColor = .labelColor
    editor.textContainerInset = NSSize(width: 0, height: 8)
    editor.isHorizontallyResizable = false
    editor.isVerticallyResizable = true
    editor.autoresizingMask = [.width]
    editor.textContainer?.widthTracksTextView = true
    editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    editor.minSize = NSSize(width: 0, height: 66)
    editor.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    editor.delegate = context.coordinator
    editor.string = text
    editor.setAccessibilityLabel(inputLabel)
    scroll.documentView = editor
    context.coordinator.editor = editor
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.parent = self
    guard let editor = scroll.documentView as? NSTextView else { return }
    if editor.string != text {
      let selection = editor.selectedRange()
      editor.string = text
      let location = min(selection.location, (text as NSString).length)
      editor.setSelectedRange(NSRange(location: location, length: 0))
    }
    editor.textColor = .labelColor
    editor.insertionPointColor = .labelColor
    editor.setAccessibilityLabel(inputLabel)
    if wantsFocus, scroll.window?.firstResponder !== editor {
      DispatchQueue.main.async { scroll.window?.makeFirstResponder(editor) }
    }
  }
  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: PromptEditor
    weak var editor: NSTextView?
    init(_ parent: PromptEditor) { self.parent = parent }
    func textDidChange(_ notification: Notification) {
      guard let editor else { return }
      parent.text = editor.string
    }
    func textDidBeginEditing(_ notification: Notification) {
      if !parent.wantsFocus { parent.wantsFocus = true }
    }
    func textDidEndEditing(_ notification: Notification) {
      if parent.wantsFocus { parent.wantsFocus = false }
    }
  }
}
