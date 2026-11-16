import MeshChatCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The message field. Mentions picked while writing read "@Name" in bold and the accent colour, as in
/// the bubbles, instead of MeshCore's "@[Name]": `picked` are the names to show that way. Grows to six
/// lines, then scrolls; Return sends.
struct MessageField: View {
    let placeholder: String
    @Binding var text: String
    var picked: [String]
    @Binding var focused: Bool
    var onSubmit: () -> Void

    var body: some View {
        #if os(iOS)
        MentionTextView(text: $text, picked: picked, focused: $focused, placeholder: placeholder, onSubmit: onSubmit)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).foregroundStyle(Color(uiColor: .placeholderText)).lineLimit(1)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
        #else
        PlainMessageField(placeholder: placeholder, text: $text, focused: $focused, onSubmit: onSubmit)
        #endif
    }
}

#if os(iOS)
/// A UITextView, since a SwiftUI text field can't colour part of its text.
private struct MentionTextView: UIViewRepresentable {
    @Binding var text: String
    var picked: [String]
    @Binding var focused: Bool
    let placeholder: String
    var onSubmit: () -> Void

    static let lines = 6

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.delegate = context.coordinator
        v.backgroundColor = .clear
        v.font = Coordinator.body
        v.adjustsFontForContentSizeCategory = true
        v.textContainerInset = .zero
        v.textContainer.lineFragmentPadding = 0
        // it sits above the keyboard and the home indicator: left to itself, it would inset its text by them
        v.contentInsetAdjustmentBehavior = .never
        v.showsVerticalScrollIndicator = false
        v.returnKeyType = .send
        v.isScrollEnabled = false
        v.accessibilityLabel = placeholder
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.text = text
        context.coordinator.restyle(v)
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        let c = context.coordinator
        c.parent = self
        v.accessibilityLabel = placeholder
        if v.text != text {
            v.text = text
            c.restyle(v)
            // set from outside (a mention picked, a message sent): carry on at the end
            v.selectedRange = NSRange(location: (v.text as NSString).length, length: 0)
        } else if c.styledFor != picked {
            c.restyle(v)
        }
        if focused, !v.isFirstResponder {
            DispatchQueue.main.async { if v.window != nil { v.becomeFirstResponder() } }
        } else if !focused, v.isFirstResponder {
            DispatchQueue.main.async { v.resignFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView v: UITextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 240
        let fit = v.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let line = ceil(Coordinator.body.lineHeight)
        let most = line * CGFloat(Self.lines)
        let scrolls = fit > most + 1
        if v.isScrollEnabled != scrolls { DispatchQueue.main.async { v.isScrollEnabled = scrolls } }
        return CGSize(width: width, height: min(max(fit, line), most))
    }

    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MentionTextView
        /// the names the text was last styled for
        var styledFor: [String] = []

        init(_ parent: MentionTextView) { self.parent = parent }

        static var body: UIFont { .preferredFont(forTextStyle: .body) }
        static var mention: UIFont { UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold)) }
        static var plain: [NSAttributedString.Key: Any] { [.font: body, .foregroundColor: UIColor.label] }

        /// Plain text, with the mentions bold and tinted. Only attributes change, so the cursor stays
        /// where it is; not while the keyboard is still composing a word (marked text).
        func restyle(_ v: UITextView) {
            styledFor = parent.picked
            guard v.markedTextRange == nil else { return }
            let s = v.textStorage, text = s.string
            s.beginEditing()
            s.setAttributes(Self.plain, range: NSRange(location: 0, length: s.length))
            for span in Mentions.spans(of: parent.picked, in: text) {
                s.addAttributes([.font: Self.mention, .foregroundColor: UIColor(Color.accentColor)], range: NSRange(span, in: text))
            }
            s.endEditing()
            v.typingAttributes = Self.plain
        }

        func textViewDidChange(_ v: UITextView) {
            parent.text = v.text
            restyle(v)
        }

        func textViewDidChangeSelection(_ v: UITextView) {
            // what's typed next is plain, even right after a mention
            v.typingAttributes = Self.plain
        }

        func textView(_ v: UITextView, shouldChangeTextIn range: NSRange, replacementText t: String) -> Bool {
            if t == "\n" { parent.onSubmit(); return false }
            return true
        }

        func textViewDidBeginEditing(_ v: UITextView) { if !parent.focused { parent.focused = true } }
        func textViewDidEndEditing(_ v: UITextView) { if parent.focused { parent.focused = false } }
    }
}
#else
/// Elsewhere (the package's macOS build): a plain field, mentions uncoloured.
private struct PlainMessageField: View {
    let placeholder: String
    @Binding var text: String
    @Binding var focused: Bool
    var onSubmit: () -> Void
    @FocusState private var focus: Bool

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .lineLimit(1...6)
            .focused($focus)
            .onSubmit(onSubmit)
            .onChange(of: focused) { _, now in focus = now }
            .onChange(of: focus) { _, now in focused = now }
    }
}
#endif
