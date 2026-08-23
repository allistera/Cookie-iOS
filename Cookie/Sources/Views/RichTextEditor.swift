import SwiftUI
import UIKit

/// Drives the composer's format bar: applies styles to the attached
/// `UITextView` and reports which styles are active at the selection so the
/// buttons can highlight. The formatting rules themselves live in `RichText`.
@MainActor
@Observable
final class RichTextController {
    fileprivate weak var textView: UITextView?
    /// Called after a format action mutates the text view, so the editor's
    /// binding picks up programmatic changes (delegate callbacks don't fire).
    var contentChanged: (() -> Void)?

    private(set) var activeStyles: Set<RichTextStyle> = []

    func toggle(_ style: RichTextStyle) {
        guard let textView else { return }
        let selection = textView.selectedRange

        switch style {
        case .bulletList:
            let (newText, newSelection) = RichText.toggleBulletList(
                in: textView.attributedText,
                range: selection
            )
            textView.attributedText = newText
            textView.selectedRange = newSelection
            syncTypingAttributes(at: newSelection.location, of: textView)

        case .bold, .italic, .underline:
            let isTurningOn = !activeStyles.contains(style)
            if selection.length > 0 {
                textView.attributedText = RichText.setStyle(
                    style,
                    active: isTurningOn,
                    in: textView.attributedText,
                    range: selection
                )
                // Replacing attributedText drops the selection — restore it.
                textView.selectedRange = selection
            }
            // Keep typing attributes in step so continued typing matches.
            textView.typingAttributes = RichText.updatingTypingAttributes(
                textView.typingAttributes,
                style: style,
                active: isTurningOn
            )
        }

        contentChanged?()
        refreshActiveStyles()
    }

    /// Recomputes button highlight state from the current selection. For a
    /// collapsed caret this reflects `typingAttributes` (what typing next
    /// would produce) plus the bullet state of the surrounding paragraph.
    func refreshActiveStyles() {
        guard let textView else { return }
        let selection = textView.selectedRange

        if selection.length > 0 {
            activeStyles = RichText.styles(in: textView.attributedText, range: selection)
            return
        }

        let probe = NSAttributedString(string: " ", attributes: textView.typingAttributes)
        var styles = RichText.styles(in: probe, range: NSRange(location: 0, length: 1))
        if textView.attributedText.length > 0 {
            let index = min(selection.location, textView.attributedText.length - 1)
            if RichText.paragraphContaining(index: index, in: textView.attributedText)
                .hasPrefix(RichText.bulletPrefix) {
                styles.insert(.bulletList)
            }
        }
        activeStyles = styles
    }

    /// Setting `attributedText` resets typing attributes to defaults; copy
    /// them back from the character at the caret so continued typing keeps
    /// its style.
    private func syncTypingAttributes(at location: Int, of textView: UITextView) {
        guard textView.attributedText.length > 0 else { return }
        let index = min(max(location, 0), textView.attributedText.length - 1)
        textView.typingAttributes = textView.attributedText.attributes(
            at: index,
            effectiveRange: nil
        )
    }
}

/// A rich-text body editor backed by `UITextView` (SwiftUI's `TextEditor` is
/// plain-text only). Pair with a `RichTextController` for the format bar.
struct RichTextEditor: UIViewRepresentable {
    @Binding var text: NSAttributedString
    let controller: RichTextController

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.allowsEditingTextAttributes = true
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        textView.delegate = context.coordinator
        textView.attributedText = text

        context.coordinator.textView = textView
        controller.textView = textView
        controller.contentChanged = { [weak coordinator = context.coordinator] in
            coordinator?.pushTextToBinding()
        }
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.textView = textView
        controller.textView = textView

        // Only push external changes into the view — comparing first avoids
        // clobbering the selection on every keystroke round-trip.
        if !textView.attributedText.isEqual(to: text) {
            textView.attributedText = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RichTextEditor
        weak var textView: UITextView?

        init(_ parent: RichTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.attributedText
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            parent.controller.refreshActiveStyles()
        }

        fileprivate func pushTextToBinding() {
            guard let textView else { return }
            parent.text = textView.attributedText
        }
    }
}
