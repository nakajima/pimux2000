import SwiftUI

struct MarkdownTextView: UIViewRepresentable {
	let attributedText: NSAttributedString
	var isSelectable: Bool = false

	func makeUIView(context _: Context) -> UITextView {
		let textView = UITextView()
		textView.isEditable = false
		textView.isScrollEnabled = false
		textView.backgroundColor = .clear
		textView.textContainerInset = .zero
		textView.textContainer.lineFragmentPadding = 0
		textView.adjustsFontForContentSizeCategory = true
		textView.setContentCompressionResistancePriority(.required, for: .vertical)
		return textView
	}

	func updateUIView(_ textView: UITextView, context _: Context) {
		if textView.attributedText != attributedText {
			textView.attributedText = attributedText
		}
		textView.isSelectable = isSelectable
	}

	func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context _: Context) -> CGSize? {
		let targetWidth = proposal.width ?? uiView.bounds.width
		guard targetWidth > 0 else { return nil }
		let size = uiView.sizeThatFits(CGSize(width: targetWidth, height: CGFloat.greatestFiniteMagnitude))
		return CGSize(width: targetWidth, height: ceil(size.height))
	}
}
