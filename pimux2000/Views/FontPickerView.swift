import SwiftUI
import UIKit

struct FontPickerView: View {
	@AppStorage("chatFontFamily") private var chatFontFamily: String = ""
	@State private var searchText = ""

	private var fontFamilies: [String] {
		UIFont.familyNames.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
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
								.font(.custom(family, size: UIFont.preferredFont(forTextStyle: .body).pointSize))
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
		.searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search fonts")
		.navigationTitle("Chat Font")
	}
}

// MARK: - Font helper

func chatFont(style: Font.TextStyle = .body) -> Font {
	let family = UserDefaults.standard.string(forKey: "chatFontFamily") ?? ""
	if family.isEmpty {
		return Font.system(style)
	}
	return .custom(family, size: UIFont.preferredFont(forTextStyle: style.uiKit).pointSize, relativeTo: style)
}

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

#Preview {
	NavigationStack {
		FontPickerView()
	}
}
