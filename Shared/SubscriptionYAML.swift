import Foundation

/// A minimal YAML reader for the community configuration format. Supports the
/// subset those files actually use: block mappings and sequences, flow
/// mappings and sequences, quoted strings, comments, and plain scalars
/// (bool/int/string). No anchors, aliases, or multi-line scalars.
enum SubscriptionYAML {
    static func parseDocument(_ text: String) -> [String: Any]? {
        let lines = sanitizedLines(text)
        guard !lines.isEmpty else { return nil }
        let (value, _) = parseBlock(lines: lines, start: 0, indent: lines[0].indent)
        return value as? [String: Any]
    }

    // MARK: - Block structure

    private struct Line {
        var indent: Int
        var content: String
    }

    private static func sanitizedLines(_ text: String) -> [Line] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let withoutComment = stripComment(String(raw))
            let trimmed = withoutComment.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed != "---", trimmed != "..." else { return nil }
            let indent = withoutComment.count - withoutComment.drop(while: { $0 == " " }).count
            return Line(indent: indent, content: trimmed)
        }
    }

    private static func stripComment(_ line: String) -> String {
        var inSingle = false
        var inDouble = false
        var previousWasSpace = true
        for (offset, char) in line.enumerated() {
            switch char {
            case "'" where !inDouble: inSingle.toggle()
            case "\"" where !inSingle: inDouble.toggle()
            case "#" where !inSingle && !inDouble && previousWasSpace:
                return String(line.prefix(offset))
            default: break
            }
            previousWasSpace = char == " " || char == "\t"
        }
        return line
    }

    private static func isSequenceItem(_ content: String) -> Bool {
        content == "-" || content.hasPrefix("- ")
    }

    private static func parseBlock(lines: [Line], start: Int, indent: Int) -> (Any, Int) {
        guard start < lines.count else { return (NSNull(), start) }
        if isSequenceItem(lines[start].content) {
            return parseSequence(lines: lines, start: start, indent: indent)
        }
        return parseMapping(lines: lines, start: start, indent: indent)
    }

    private static func parseSequence(lines: [Line], start: Int, indent: Int) -> (Any, Int) {
        var items: [Any] = []
        var i = start
        while i < lines.count, lines[i].indent == indent, isSequenceItem(lines[i].content) {
            let content = lines[i].content
            let afterDash = content.dropFirst(1)
            let spaces = afterDash.prefix(while: { $0 == " " }).count
            let rest = String(afterDash.dropFirst(spaces))
            if rest.isEmpty {
                i += 1
                if i < lines.count, lines[i].indent > indent {
                    let (child, next) = parseBlock(lines: lines, start: i, indent: lines[i].indent)
                    items.append(child)
                    i = max(next, i)
                } else {
                    items.append(NSNull())
                }
            } else if rest.hasPrefix("{") || rest.hasPrefix("[") || splitKeyValue(rest) == nil {
                items.append(parseScalar(rest))
                i += 1
            } else {
                // "- key: value" begins a mapping whose keys sit to the right
                // of the dash; re-anchor that line at the key column and
                // re-parse from there.
                let itemIndent = indent + 1 + spaces
                var anchored = lines
                anchored[i] = Line(indent: itemIndent, content: rest)
                let (child, next) = parseBlock(lines: anchored, start: i, indent: itemIndent)
                items.append(child)
                i = max(next, i + 1)
            }
        }
        return (items, i)
    }

    private static func parseMapping(lines: [Line], start: Int, indent: Int) -> (Any, Int) {
        var map: [String: Any] = [:]
        var i = start
        while i < lines.count, lines[i].indent == indent, !isSequenceItem(lines[i].content) {
            guard let (key, valueText) = splitKeyValue(lines[i].content) else { break }
            if valueText.isEmpty {
                i += 1
                if i < lines.count, lines[i].indent > indent {
                    let (child, next) = parseBlock(lines: lines, start: i, indent: lines[i].indent)
                    map[key] = child
                    i = max(next, i)
                } else {
                    map[key] = NSNull()
                }
            } else {
                map[key] = parseScalar(valueText)
                i += 1
            }
        }
        return (map, i)
    }

    private static func splitKeyValue(_ content: String) -> (String, String)? {
        var inSingle = false
        var inDouble = false
        for (offset, char) in content.enumerated() {
            switch char {
            case "'" where !inDouble: inSingle.toggle()
            case "\"" where !inSingle: inDouble.toggle()
            case ":" where !inSingle && !inDouble:
                let after = content.index(content.startIndex, offsetBy: offset + 1)
                if after == content.endIndex || content[after] == " " || content[after] == "\t" {
                    let key = String(content.prefix(offset))
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    let value = String(content[after...]).trimmingCharacters(in: .whitespaces)
                    return (key, value)
                }
            default: break
            }
        }
        return nil
    }

    // MARK: - Scalars and flow collections

    private static func parseScalar(_ text: String) -> Any {
        var index = text.startIndex
        skipWhitespace(text, &index)
        guard index < text.endIndex else { return NSNull() }
        let char = text[index]
        if char == "[" || char == "{" || char == "\"" || char == "'" {
            return parseFlowValue(text, &index)
        }
        return convertScalar(String(text[index...]).trimmingCharacters(in: .whitespaces))
    }

    private static func parseFlowValue(_ text: String, _ index: inout String.Index) -> Any {
        skipWhitespace(text, &index)
        guard index < text.endIndex else { return NSNull() }
        switch text[index] {
        case "[":
            index = text.index(after: index)
            var items: [Any] = []
            while index < text.endIndex {
                skipWhitespace(text, &index)
                if index < text.endIndex, text[index] == "]" {
                    index = text.index(after: index)
                    break
                }
                items.append(parseFlowValue(text, &index))
                skipWhitespace(text, &index)
                if index < text.endIndex, text[index] == "," {
                    index = text.index(after: index)
                }
            }
            return items
        case "{":
            index = text.index(after: index)
            var map: [String: Any] = [:]
            while index < text.endIndex {
                skipWhitespace(text, &index)
                if index < text.endIndex, text[index] == "}" {
                    index = text.index(after: index)
                    break
                }
                let key = parseFlowKey(text, &index)
                skipWhitespace(text, &index)
                if index < text.endIndex, text[index] == ":" {
                    index = text.index(after: index)
                }
                map[key] = parseFlowValue(text, &index)
                skipWhitespace(text, &index)
                if index < text.endIndex, text[index] == "," {
                    index = text.index(after: index)
                }
            }
            return map
        case "\"", "'":
            return parseQuoted(text, &index)
        default:
            var result = ""
            while index < text.endIndex, !",]}".contains(text[index]) {
                result.append(text[index])
                index = text.index(after: index)
            }
            return convertScalar(result.trimmingCharacters(in: .whitespaces))
        }
    }

    private static func parseFlowKey(_ text: String, _ index: inout String.Index) -> String {
        if text[index] == "\"" || text[index] == "'" {
            return parseQuoted(text, &index)
        }
        var result = ""
        while index < text.endIndex, !":,}] ".contains(text[index]) {
            result.append(text[index])
            index = text.index(after: index)
        }
        return result
    }

    private static func parseQuoted(_ text: String, _ index: inout String.Index) -> String {
        let quote = text[index]
        index = text.index(after: index)
        var result = ""
        while index < text.endIndex {
            let char = text[index]
            if quote == "\"" && char == "\\" {
                let next = text.index(after: index)
                if next < text.endIndex {
                    switch text[next] {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    case let other: result.append(other)
                    }
                    index = text.index(after: next)
                    continue
                }
            }
            if char == quote {
                if quote == "'" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "'" {
                        result.append("'")
                        index = text.index(after: next)
                        continue
                    }
                }
                index = text.index(after: index)
                return result
            }
            result.append(char)
            index = text.index(after: index)
        }
        return result
    }

    private static func convertScalar(_ raw: String) -> Any {
        switch raw.lowercased() {
        case "true": return true
        case "false": return false
        case "null", "~", "": return NSNull()
        default: break
        }
        if let int = Int(raw) { return int }
        return raw
    }

    private static func skipWhitespace(_ text: String, _ index: inout String.Index) {
        while index < text.endIndex, text[index] == " " || text[index] == "\t" {
            index = text.index(after: index)
        }
    }
}
