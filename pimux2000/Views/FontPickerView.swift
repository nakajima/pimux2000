import SwiftUI
import CoreText
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct FontPickerView: View {
	@AppStorage("chatFontFamily") private var chatFontFamily: String = ""
	@State private var searchText = ""
	@State private var fontOptions: [MonospacedFontOption] = []

	private var filteredFontOptions: [MonospacedFontOption] {
		if searchText.isEmpty { return fontOptions }
		return fontOptions.filter {
			$0.familyName.localizedCaseInsensitiveContains(searchText)
			|| $0.previewFontName.localizedCaseInsensitiveContains(searchText)
		}
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

				ForEach(filteredFontOptions) { option in
					Button {
						chatFontFamily = option.familyName
					} label: {
						HStack {
							Text(option.familyName)
								.font(.custom(option.previewFontName, size: preferredFontSize(for: .body)))
							Spacer()
							if chatFontFamily == option.familyName {
								Image(systemName: "checkmark")
									.foregroundStyle(.tint)
							}
						}
					}
				}
			} header: {
				Text("Monospaced Fonts")
			} footer: {
				Text("Only fixed-width fonts currently available to the app are shown.")
			}
		}
		#if os(iOS)
		.searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search fonts")
		#else
		.searchable(text: $searchText, prompt: "Search fonts")
		#endif
		.navigationTitle("Chat Font")
		.toolbar {
			ToolbarItem(placement: .primaryAction) {
				Button {
					reloadFonts()
				} label: {
					Label("Reload Fonts", systemImage: "arrow.clockwise")
				}
			}
		}
		.onAppear(perform: reloadFonts)
	}

	private func reloadFonts() {
		fontOptions = ChatFontCatalog.monospacedFontOptions()
	}
}

private struct MonospacedFontOption: Identifiable, Hashable {
	let familyName: String
	let previewFontName: String

	var id: String { familyName }
}

private struct FontFace {
	let fontName: String
	let styleName: String
}

private enum ChatFontCatalog {
	static func monospacedFontOptions() -> [MonospacedFontOption] {
		let descriptors = (CTFontCollectionCreateMatchingFontDescriptors(CTFontCollectionCreateFromAvailableFonts(nil)) as? [CTFontDescriptor]) ?? []
		var facesByFamily: [String: [FontFace]] = [:]

		for descriptor in descriptors {
			let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
			guard CTFontGetSymbolicTraits(font).contains(.traitMonoSpace) else { continue }

			let familyName = CTFontCopyFamilyName(font) as String
			let fontName = CTFontCopyPostScriptName(font) as String
			let styleName = (CTFontCopyName(font, kCTFontStyleNameKey) as String?) ?? "Regular"
			facesByFamily[familyName, default: []].append(FontFace(fontName: fontName, styleName: styleName))
		}

		return facesByFamily.map { familyName, faces in
			MonospacedFontOption(
				familyName: familyName,
				previewFontName: preferredFace(in: faces).fontName
			)
		}
		.sorted { $0.familyName.localizedCaseInsensitiveCompare($1.familyName) == .orderedAscending }
	}

	static func resolvedFontName(forStoredValue storedValue: String) -> String {
		guard !storedValue.isEmpty else { return "" }

		let postScriptNames = Set((CTFontManagerCopyAvailablePostScriptNames() as? [String]) ?? [])
		if postScriptNames.contains(storedValue) {
			return storedValue
		}

		if let option = monospacedFontOptions().first(where: { $0.familyName == storedValue }) {
			return option.previewFontName
		}

		return storedValue
	}

	private static func preferredFace(in faces: [FontFace]) -> FontFace {
		faces.min { score(for: $0) < score(for: $1) } ?? FontFace(fontName: "Menlo-Regular", styleName: "Regular")
	}

	private static func score(for face: FontFace) -> Int {
		let style = face.styleName.lowercased()
		var score = 0

		if style == "regular" || style == "roman" || style == "book" || style == "text" {
			score -= 1000
		}
		if style.contains("medium") {
			score -= 200
		}
		if style.contains("bold") {
			score += 200
		}
		if style.contains("italic") || style.contains("oblique") {
			score += 400
		}
		if style.contains("condensed") || style.contains("compressed") || style.contains("expanded") {
			score += 100
		}
		if style.contains("thin") || style.contains("light") || style.contains("black") {
			score += 50
		}

		return score
	}
}

// MARK: - Font helper

func chatFont(style: Font.TextStyle = .body) -> Font {
	let storedValue = UserDefaults.standard.string(forKey: "chatFontFamily") ?? ""
	let resolvedFontName = ChatFontCatalog.resolvedFontName(forStoredValue: storedValue)
	if resolvedFontName.isEmpty {
		return Font.system(style)
	}
	return .custom(resolvedFontName, size: preferredFontSize(for: style), relativeTo: style)
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
