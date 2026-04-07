import Foundation

struct OrderedListItem: Equatable {
	var ordinal: Int
	var text: String
}

enum MarkdownBlock: Equatable {
	case heading(level: Int, text: String)
	case paragraph(text: String)
	case codeBlock(language: String?, code: String)
	case blockQuote(content: String)
	case unorderedList(items: [String])
	case orderedList(items: [OrderedListItem])
	case thematicBreak
}

enum MarkdownBlockParser {
	private static let cache = MarkdownBlockCache()

	static func parse(_ markdown: String) -> [MarkdownBlock] {
		if let cached = cache.get(markdown) {
			return cached
		}
		let result = parseUncached(markdown)
		cache.set(result, for: markdown)
		return result
	}

	private static func parseUncached(_ markdown: String) -> [MarkdownBlock] {
		let lines = markdown.components(separatedBy: .newlines)
		var blocks: [MarkdownBlock] = []
		var i = 0

		while i < lines.count {
			let line = lines[i]
			let trimmed = line.trimmingCharacters(in: .whitespaces)

			// Blank line — skip
			if trimmed.isEmpty {
				i += 1
				continue
			}

			// Fenced code block
			if trimmed.hasPrefix("```") {
				let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
				var codeLines: [String] = []
				i += 1
				while i < lines.count {
					if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
						i += 1
						break
					}
					codeLines.append(lines[i])
					i += 1
				}
				let code = codeLines.joined(separator: "\n")
				blocks.append(.codeBlock(language: language.isEmpty ? nil : language, code: code))
				continue
			}

			// Thematic break
			if trimmed == "---" || trimmed == "***" || trimmed == "___" {
				blocks.append(.thematicBreak)
				i += 1
				continue
			}

			// Heading
			if let heading = parseHeading(trimmed) {
				blocks.append(heading)
				i += 1
				continue
			}

			// Block quote
			if trimmed.hasPrefix(">") {
				var quoteLines: [String] = []
				while i < lines.count {
					let l = lines[i]
					let lt = l.trimmingCharacters(in: .whitespaces)
					if lt.hasPrefix("> ") {
						quoteLines.append(String(lt.dropFirst(2)))
					} else if lt.hasPrefix(">") {
						quoteLines.append(String(lt.dropFirst(1)))
					} else if lt.isEmpty, !quoteLines.isEmpty {
						// Blank line inside a block quote can be a paragraph break
						quoteLines.append("")
						i += 1
						// Peek: if next line is also a quote, continue; otherwise break
						if i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
							continue
						} else {
							break
						}
					} else {
						break
					}
					i += 1
				}
				let content = quoteLines.joined(separator: "\n")
					.trimmingCharacters(in: .whitespacesAndNewlines)
				if !content.isEmpty {
					blocks.append(.blockQuote(content: content))
				}
				continue
			}

			// Unordered list
			if isUnorderedListMarker(trimmed) {
				var items: [String] = []
				while i < lines.count {
					let l = lines[i]
					let lt = l.trimmingCharacters(in: .whitespaces)
					if isUnorderedListMarker(lt) {
						items.append(stripUnorderedMarker(lt))
						i += 1
						// Collect continuation lines
						while i < lines.count {
							let cl = lines[i]
							if cl.isEmpty || isBlockStart(cl.trimmingCharacters(in: .whitespaces)) {
								break
							}
							if cl.hasPrefix("  ") || cl.hasPrefix("\t") {
								items[items.count - 1] += "\n" + cl.trimmingCharacters(in: .whitespaces)
								i += 1
							} else {
								break
							}
						}
					} else if lt.isEmpty {
						i += 1
						// Peek: if next is another list item, continue; otherwise break
						if i < lines.count, isUnorderedListMarker(lines[i].trimmingCharacters(in: .whitespaces)) {
							continue
						} else {
							break
						}
					} else {
						break
					}
				}
				if !items.isEmpty {
					blocks.append(.unorderedList(items: items))
				}
				continue
			}

			// Ordered list
			if let (ordinal, text) = parseOrderedListItem(trimmed) {
				var items: [OrderedListItem] = [OrderedListItem(ordinal: ordinal, text: text)]
				i += 1
				while i < lines.count {
					let l = lines[i]
					let lt = l.trimmingCharacters(in: .whitespaces)
					if let (ord, txt) = parseOrderedListItem(lt) {
						items.append(OrderedListItem(ordinal: ord, text: txt))
						i += 1
						// Collect continuation lines
						while i < lines.count {
							let cl = lines[i]
							if cl.isEmpty || isBlockStart(cl.trimmingCharacters(in: .whitespaces)) {
								break
							}
							if cl.hasPrefix("  ") || cl.hasPrefix("\t") {
								items[items.count - 1].text += "\n" + cl.trimmingCharacters(in: .whitespaces)
								i += 1
							} else {
								break
							}
						}
					} else if lt.isEmpty {
						i += 1
						if i < lines.count, parseOrderedListItem(lines[i].trimmingCharacters(in: .whitespaces)) != nil {
							continue
						} else {
							break
						}
					} else {
						break
					}
				}
				blocks.append(.orderedList(items: items))
				continue
			}

			// Paragraph — collect lines until blank line or block start
			var paraLines: [String] = []
			while i < lines.count {
				let l = lines[i]
				let lt = l.trimmingCharacters(in: .whitespaces)
				if lt.isEmpty { break }
				if !paraLines.isEmpty, isBlockStart(lt) { break }
				paraLines.append(l)
				i += 1
			}
			let paraText = paraLines.joined(separator: "\n")
				.trimmingCharacters(in: .whitespacesAndNewlines)
			if !paraText.isEmpty {
				blocks.append(.paragraph(text: paraText))
			}
		}

		return blocks
	}

	// MARK: - Helpers

	private static func parseHeading(_ line: String) -> MarkdownBlock? {
		var level = 0
		for ch in line {
			if ch == "#" { level += 1 } else { break }
		}
		guard level >= 1, level <= 6 else { return nil }
		guard line.count > level else {
			return .heading(level: level, text: "")
		}
		let rest = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
		return .heading(level: level, text: rest)
	}

	private static func isUnorderedListMarker(_ line: String) -> Bool {
		line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
	}

	private static func stripUnorderedMarker(_ line: String) -> String {
		String(line.dropFirst(2))
	}

	private static func parseOrderedListItem(_ line: String) -> (ordinal: Int, text: String)? {
		guard let dotIndex = line.firstIndex(of: ".") else { return nil }
		let prefix = line[line.startIndex ..< dotIndex]
		guard let ordinal = Int(prefix) else { return nil }
		let afterDot = line.index(after: dotIndex)
		guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
		let text = String(line[line.index(after: afterDot)...])
		return (ordinal, text)
	}

	private static func isBlockStart(_ line: String) -> Bool {
		line.hasPrefix("```")
			|| line.hasPrefix("#")
			|| line.hasPrefix("> ")
			|| line == "---" || line == "***" || line == "___"
			|| isUnorderedListMarker(line)
			|| parseOrderedListItem(line) != nil
	}
}

// MARK: - Block parse cache

private final class MarkdownBlockCacheKey: NSObject {
	let text: String

	init(_ text: String) {
		self.text = text
		super.init()
	}

	override var hash: Int {
		text.hashValue
	}

	override func isEqual(_ object: Any?) -> Bool {
		(object as? MarkdownBlockCacheKey)?.text == text
	}
}

private final class MarkdownBlockCacheValue {
	let blocks: [MarkdownBlock]
	init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
}

private final class MarkdownBlockCache: @unchecked Sendable {
	private let cache: NSCache<MarkdownBlockCacheKey, MarkdownBlockCacheValue> = {
		let c = NSCache<MarkdownBlockCacheKey, MarkdownBlockCacheValue>()
		c.countLimit = 512
		return c
	}()

	func get(_ text: String) -> [MarkdownBlock]? {
		cache.object(forKey: MarkdownBlockCacheKey(text))?.blocks
	}

	func set(_ blocks: [MarkdownBlock], for text: String) {
		cache.setObject(MarkdownBlockCacheValue(blocks), forKey: MarkdownBlockCacheKey(text))
	}
}
