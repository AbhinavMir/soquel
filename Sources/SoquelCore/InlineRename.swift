import AppKit

/// Renaming in place, the way Finder does it.
///
/// A table's own `editColumn(_:row:with:select:)` was the obvious route and it
/// is the wrong one: it refuses without a double click behind it, it only
/// exists for the list, and it puts the editor wherever the cell happens to be
/// rather than where the name is drawn. This is a text field placed over the
/// name, so the same gesture behaves the same way in every view.
final class InlineRenameEditor: NSObject, NSTextFieldDelegate {
    /// The field currently on screen, if any. One at a time: a second rename
    /// while the first is open would leave an orphan taking keystrokes.
    private var field: NSTextField?
    private var commit: ((String) -> Void)?
    private var finished = false

    var isEditing: Bool { field != nil }

    /// Puts an editor over `rect` in `host`, holding `name` with everything
    /// before the extension selected.
    ///
    /// - Parameter commit: called with the new name, once, only when it differs
    ///   from the old one. Escape and an empty name call nothing.
    func begin(
        name: String, in host: NSView, rect: NSRect,
        alignment: NSTextAlignment = .left, font: NSFont? = nil,
        commit: @escaping (String) -> Void
    ) {
        cancel()

        let field = NSTextField(string: name)
        field.font = font ?? Theme.rowName
        field.alignment = alignment
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .squareBezel
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.textColor = .textColor
        field.focusRingType = .exterior
        // A bezel alone let the row's highlight and the old name show through,
        // so the two names were legible on top of each other. A layer of its
        // own is what actually covers what is underneath.
        field.wantsLayer = true
        field.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        field.layer?.cornerRadius = 3
        field.layer?.borderWidth = 1
        field.layer?.borderColor = NSColor.separatorColor.cgColor
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byClipping
        field.delegate = self
        // A name longer than its cell should still be readable, so the field is
        // widened rather than the name truncated.
        field.frame = Self.frame(for: rect, in: host, fitting: name, font: field.font)

        host.addSubview(field)
        self.field = field
        self.commit = commit
        self.finished = false
        self.original = name

        // Whatever had focus gets it back when the editor goes, or the click
        // that dismissed it lands on a view that is no longer listening.
        previousResponder = host.window?.firstResponder as? NSView
        host.window?.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            editor.selectedRange = Self.selection(for: name)
        }
    }

    private var original = ""
    private weak var previousResponder: NSView?

    /// The extension left out of the selection, so the first keystroke replaces
    /// the name and not the type. A dotfile has no extension to protect.
    static func selection(for name: String) -> NSRange {
        let base = (name as NSString).deletingPathExtension
        guard !base.isEmpty, base.count < name.count else {
            return NSRange(location: 0, length: (name as NSString).length)
        }
        return NSRange(location: 0, length: (base as NSString).length)
    }

    /// Grown to fit the name, clamped to the host so it cannot hang off the
    /// edge, and never shorter than the cell it covers.
    static func frame(for rect: NSRect, in host: NSView, fitting name: String, font: NSFont?) -> NSRect {
        let attributes: [NSAttributedString.Key: Any] = font.map { [.font: $0] } ?? [:]
        let measured = (name as NSString).size(withAttributes: attributes).width + 18
        var frame = rect
        frame.size.width = max(rect.width, min(measured, host.bounds.width - rect.minX - 4))
        // Grown about the middle of the cell. Growing from the origin pushed the
        // editor half a row off, so it covered the name above the one being
        // renamed.
        frame.size.height = max(rect.height, 20)
        frame.origin.y = rect.midY - frame.height / 2
        frame.origin.x = max(0, min(frame.minX, host.bounds.width - frame.width))
        return frame
    }

    /// Takes the editor away without committing.
    func cancel() {
        finished = true
        let window = field?.window
        field?.removeFromSuperview()
        field = nil
        commit = nil
        if let previousResponder { window?.makeFirstResponder(previousResponder) }
    }

    /// Takes the editor away and reports the new name, unless nothing changed.
    private func finish() {
        guard !finished, let field else { return }
        finished = true
        let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = self.commit
        let window = field.window
        field.removeFromSuperview()
        self.field = nil
        self.commit = nil
        if let previousResponder { window?.makeFirstResponder(previousResponder) }
        guard !typed.isEmpty, typed != original, let commit else { return }
        // Committing rebuilds the rows, and doing that inside the click that
        // dismissed the editor pulls the view out from under the click still
        // being delivered — in the column browser that read as the parent
        // column closing. The rename happens once the click is finished.
        DispatchQueue.main.async { commit(typed) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            finish()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        case #selector(NSResponder.insertTab(_:)):
            finish()
            return true
        default:
            return false
        }
    }

    /// Clicking elsewhere commits, as Finder does. Escape has already set
    /// `finished`, so cancelling does not come back through here.
    func controlTextDidEndEditing(_ obj: Notification) {
        finish()
    }
}
