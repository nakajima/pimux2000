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
		fontOptions = ChatFontCatalog.monospacedFontOptions(forceReload: true)
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
	private static var cachedOptions: [MonospacedFontOption]?

	static func monospacedFontOptions(forceReload: Bool = false) -> [MonospacedFontOption] {
		if !forceReload, let cachedOptions {
			return cachedOptions
		}

		let options: [MonospacedFontOption]
		#if canImport(UIKit)
		options = iOSMonospacedFontOptions()
		#elseif canImport(AppKit)
		options = macOSMonospacedFontOptions()
		#else
		options = []
		#endif

		cachedOptions = options
		return options
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

	private static func buildOptions(from facesByFamily: [String: [FontFace]]) -> [MonospacedFontOption] {
		facesByFamily.map { familyName, faces in
			MonospacedFontOption(
				familyName: familyName,
				previewFontName: preferredFace(in: faces).fontName
			)
		}
		.sorted { $0.familyName.localizedCaseInsensitiveCompare($1.familyName) == .orderedAscending }
	}

	#if canImport(UIKit)
	private static func iOSMonospacedFontOptions() -> [MonospacedFontOption] {
		var facesByFamily: [String: [FontFace]] = [:]
		var seenFontNames = Set<String>()

		for familyName in UIFont.familyNames {
			for fontName in UIFont.fontNames(forFamilyName: familyName) {
				addUIKitFont(named: fontName, into: &facesByFamily, seenFontNames: &seenFontNames)
			}
		}

		for fontName in (CTFontManagerCopyAvailablePostScriptNames() as? [String]) ?? [] {
			addUIKitFont(named: fontName, into: &facesByFamily, seenFontNames: &seenFontNames)
		}

		let descriptors = (CTFontCollectionCreateMatchingFontDescriptors(CTFontCollectionCreateFromAvailableFonts(nil)) as? [CTFontDescriptor]) ?? []
		for descriptor in descriptors {
			let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
			let fontName = CTFontCopyPostScriptName(font) as String
			addUIKitFont(named: fontName, into: &facesByFamily, seenFontNames: &seenFontNames)
		}

		return buildOptions(from: facesByFamily)
	}

	private static func addUIKitFont(
		named fontName: String,
		into facesByFamily: inout [String: [FontFace]],
		seenFontNames: inout Set<String>
	) {
		guard seenFontNames.insert(fontName).inserted else { return }
		guard let font = UIFont(name: fontName, size: 12) else { return }
		guard isMonospaced(fontName: font.fontName) else { return }

		let familyName = font.familyName
		let styleName = (font.fontDescriptor.object(forKey: .face) as? String) ?? font.fontName
		facesByFamily[familyName, default: []].append(FontFace(fontName: font.fontName, styleName: styleName))
	}
	#elseif canImport(AppKit)
	private static func macOSMonospacedFontOptions() -> [MonospacedFontOption] {
		let descriptors = (CTFontCollectionCreateMatchingFontDescriptors(CTFontCollectionCreateFromAvailableFonts(nil)) as? [CTFontDescriptor]) ?? []
		var facesByFamily: [String: [FontFace]] = [:]

		for descriptor in descriptors {
			let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
			guard isMonospaced(font) else { continue }

			let familyName = CTFontCopyFamilyName(font) as String
			let fontName = CTFontCopyPostScriptName(font) as String
			let styleName = (CTFontCopyName(font, kCTFontStyleNameKey) as String?) ?? "Regular"
			facesByFamily[familyName, default: []].append(FontFace(fontName: fontName, styleName: styleName))
		}

		return buildOptions(from: facesByFamily)
	}
	#endif

	private static func isMonospaced(fontName: String) -> Bool {
		isMonospaced(CTFontCreateWithName(fontName as CFString, 12, nil))
	}

	private static func isMonospaced(_ font: CTFont) -> Bool {
		if CTFontGetSymbolicTraits(font).contains(.traitMonoSpace) {
			return true
		}
		
		if String(CTFontCopyFullName(font)).lowercased().contains("mono") {
			return true
		}
		
		return hasFixedGlyphAdvances(font)
	}

	private static func hasFixedGlyphAdvances(_ font: CTFont) -> Bool {
		let sampleCharacters: [UniChar] = Array("ilWm0._".utf16)
		var widths: [CGFloat] = []

		for sampleCharacter in sampleCharacters {
			var character = sampleCharacter
			var glyph = CGGlyph()
			guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1), glyph != 0 else { continue }

			let glyphs = [glyph]
			var advances = [CGSize.zero]
			CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, 1)

			let width = advances[0].width
			guard width > 0 else { continue }
			widths.append(width)
		}

		guard widths.count >= 4,
				let minWidth = widths.min(),
				let maxWidth = widths.max() else {
			return false
		}

		return abs(maxWidth - minWidth) < 0.01
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

func chatLineHeight(style: Font.TextStyle = .body) -> CGFloat {
	let storedValue = UserDefaults.standard.string(forKey: "chatFontFamily") ?? ""
	let resolvedFontName = ChatFontCatalog.resolvedFontName(forStoredValue: storedValue)
	let fontSize = preferredFontSize(for: style)

	#if canImport(UIKit)
	if !resolvedFontName.isEmpty, let font = UIFont(name: resolvedFontName, size: fontSize) {
		return font.lineHeight
	}
	return UIFont.preferredFont(forTextStyle: style.uiKit).lineHeight
	#else
	if !resolvedFontName.isEmpty, let font = NSFont(name: resolvedFontName, size: fontSize) {
		return font.ascender - font.descender + font.leading
	}
	let font = NSFont.preferredFont(forTextStyle: style.appKit)
	return font.ascender - font.descender + font.leading
	#endif
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
