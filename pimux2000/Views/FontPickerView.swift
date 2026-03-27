import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct FontPickerView: View {
	@AppStorage("chatFontFamily") private var chatFontFamily: String = ""
	@State private var searchText = ""

	private var fontFamilies: [String] {
		#if canImport(UIKit)
		UIFont.familyNames.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
		#else
		NSFontManager.shared.availableFontFamilies.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
		#endif
	}

	private var filteredFamilies: [String] {
		if searchText.isEmpty { return fontFamilies }
		return fontFamilies.filter { $0.localizedCaseInsensitiveContains(searchText) }
	}

	var body: some View {
		List {
			Section("Preview") {
				Text("The quick brown fox jumps over the lazy dog.")
					.font(chatFont())
			}

			Section {
				Button {
					chatFontFamily = ""
				} label: {
					HStack {
						Text("System Default")
						Spacer()
						if chatFontFamily.isEmpty {
							Image(systemName: "checkmark")
								.foregroundStyle(.tint)
						}
					}
				}

				ForEach(filteredFamilies, id: \.self) { family in
					Button {
						chatFontFamily = family
					} label: {
						HStack {
							Text(family)
								.font(.custom(family, size: preferredFontSize(for: .body)))
							Spacer()
							if chatFontFamily == family {
								Image(systemName: "checkmark")
									.foregroundStyle(.tint)
							}
						}
					}
				}
			} header: {
				Text("Fonts")
			}
		}
		#if os(iOS)
		.searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search fonts")
		#else
		.searchable(text: $searchText, prompt: "Search fonts")
		#endif
		.navigationTitle("Chat Font")
	}
}

// MARK: - Font helper

func chatFont(style: Font.TextStyle = .body) -> Font {
	let family = UserDefaults.standard.string(forKey: "chatFontFamily") ?? ""
	if family.isEmpty {
		return Font.system(style)
	}
	return .custom(family, size: preferredFontSize(for: style), relativeTo: style)
}

private func preferredFontSize(for style: Font.TextStyle) -> CGFloat {
	#if canImport(UIKit)
	UIFont.preferredFont(forTextStyle: style.uiKit).pointSize
	#else
	NSFont.preferredFont(forTextStyle: style.appKit).pointSize
	#endif
}

#if canImport(UIKit)
private extension Font.TextStyle {
	var uiKit: UIFont.TextStyle {
		switch self {
		case .largeTitle: .largeTitle
		case .title: .title1
		case .title2: .title2
		case .title3: .title3
		case .headline: .headline
		case .subheadline: .subheadline
		case .body: .body
		case .callout: .callout
		case .footnote: .footnote
		case .caption: .caption1
		case .caption2: .caption2
		@unknown default: .body
		}
	}
}
#elseif canImport(AppKit)
private extension Font.TextStyle {
	var appKit: NSFont.TextStyle {
		switch self {
		case .largeTitle: .largeTitle
		case .title: .title1
		case .title2: .title2
		case .title3: .title3
		case .headline: .headline
		case .subheadline: .subheadline
		case .body: .body
		case .callout: .callout
		case .footnote: .footnote
		case .caption: .caption1
		case .caption2: .caption2
		@unknown default: .body
		}
	}
}
#endif

#Preview {
	NavigationStack {
		FontPickerView()
	}
}
