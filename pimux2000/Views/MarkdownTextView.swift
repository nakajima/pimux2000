import SwiftUI

struct MarkdownTextView: UIViewRepresentable {
	let attributedText: NSAttributedString
	var isSelectable: Bool = false

	func makeUIView(context _: Context) -> UIView {
		if isSelectable {
			return Self.makeTextView()
		} else {
			return Self.makeLabel()
		}
	}

	func updateUIView(_ uiView: UIView, context _: Context) {
		if let label = uiView as? UILabel {
			if label.attributedText != attributedText {
				label.attributedText = attributedText
			}
		} else if let textView = uiView as? UITextView {
			if textView.attributedText != attributedText {
				textView.attributedText = attributedText
			}
			textView.isSelectable = isSelectable
		}
	}

	func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context _: Context) -> CGSize? {
		let targetWidth = proposal.width ?? uiView.bounds.width
		guard targetWidth > 0 else { return .zero }
		let size = uiView.sizeThatFits(CGSize(width: targetWidth, height: CGFloat.greatestFiniteMagnitude))
		return CGSize(width: targetWidth, height: ceil(size.height))
	}

	// MARK: - Factory

	private static func makeLabel() -> UILabel {
		let label = UILabel()
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		label.backgroundColor = nil
		label.adjustsFontForContentSizeCategory = true
		label.setContentCompressionResistancePriority(.required, for: .vertical)
		label.setContentHuggingPriority(.required, for: .vertical)
		return label
	}

	private static func makeTextView() -> UITextView {
		let textView = UITextView()
		textView.isEditable = false
		textView.isScrollEnabled = false
		textView.backgroundColor = .clear
		textView.textContainerInset = .zero
		textView.textContainer.lineFragmentPadding = 0
		textView.adjustsFontForContentSizeCategory = true
		textView.setContentCompressionResistancePriority(.required, for: .vertical)
		textView.setContentHuggingPriority(.required, for: .vertical)
		return textView
	}
}
