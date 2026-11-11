import Foundation

/// A small YAML reader covering what Clash / Mihomo subscriptions use: block mappings
/// and sequences, flow `{…}` / `[…]` collections (also spread over several lines),
/// quoted and plain scalars, comments and `|` / `>` block scalars. Anchors, tags and
/// multiple documents are not supported (Clash proxy lists do not use them).
public enum MiniYAML {
    public struct ParseError: Error, Equatable {
        public let line: Int
        public let message: String
    }

    public static func parse(_ text: String) throws -> JSONValue {
        var parser = BlockParser(text)
        return try parser.parseDocument()
    }

    // MARK: Lines

    struct Line {
        let number: Int
        let indent: Int
        var text: String // without indentation and trailing comment
    }

    static func lines(_ text: String) -> [Line] {
        var result: [Line] = []
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\t", with: "  ")
        for (index, raw) in normalized.components(separatedBy: "\n").enumerated() {
            let stripped = stripComment(raw)
            let trimmed = stripped.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "---" || trimmed == "..." || trimmed.hasPrefix("%") { continue }
            let indent = stripped.prefix { $0 == " " }.count
            result.append(Line(number: index + 1, indent: indent, text: trimmed))
        }
        return result
    }

    /// Removes a `#` comment that is outside quotes and starts the line or follows whitespace.
    static func stripComment(_ line: String) -> String {
        var quote: Character?
        var previous: Character = " "
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if let open = quote {
                if character == open {
                    if open == "'" {
                        let next = line.index(after: index)
                        if next < line.endIndex, line[next] == "'" { index = line.index(after: next); previous = "'"; continue }
                    }
                    quote = nil
                } else if character == "\\", open == "\"" {
                    index = line.index(after: index)
                    if index < line.endIndex { index = line.index(after: index) }
                    continue
                }
            } else if character == "\"" || character == "'" {
                if previous == " " || previous == "[" || previous == "{" || previous == "," || previous == ":" || previous == "-" { quote = character }
            } else if character == "#", previous == " " || previous == "\t" {
                return String(line[..<index])
            }
            previous = character
            index = line.index(after: index)
        }
        return line
    }

    // MARK: Block structure

    struct BlockParser {
        var lines: [Line]
        var position = 0

        init(_ text: String) { lines = MiniYAML.lines(text) }

        var current: Line? { position < lines.count ? lines[position] : nil }

        mutating func parseDocument() throws -> JSONValue {
            guard let first = current else { return .null }
            return try parseNode(indent: first.indent)
        }

        mutating func parseNode(indent: Int) throws -> JSONValue {
            guard let line = current else { return .null }
            if isSequenceItem(line.text) { return try parseSequence(indent: line.indent) }
            if MiniYAML.splitKey(line.text) != nil { return try parseMapping(indent: line.indent) }
            // A lone scalar or flow collection.
            position += 1
            return try value(from: line.text, line: line)
        }

        func isSequenceItem(_ text: String) -> Bool { text == "-" || text.hasPrefix("- ") }

        mutating func parseSequence(indent: Int) throws -> JSONValue {
            var items: [JSONValue] = []
            while let line = current, line.indent == indent, isSequenceItem(line.text) {
                let content = line.text == "-" ? "" : String(line.text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if content.isEmpty {
                    position += 1
                    if let next = current, next.indent > indent { items.append(try parseNode(indent: next.indent)) } else { items.append(.null) }
                } else if content.hasPrefix("{") || content.hasPrefix("[") || content.hasPrefix("\"") || content.hasPrefix("'")
                            || MiniYAML.splitKey(content) == nil {
                    position += 1
                    items.append(try value(from: content, line: line))
                } else {
                    // "- key: value" starts a mapping whose keys line up with "key".
                    let inner = indent + (line.text.count - content.count)
                    lines[position] = Line(number: line.number, indent: inner, text: content)
                    items.append(try parseMapping(indent: inner))
                }
            }
            return .array(items)
        }

        mutating func parseMapping(indent: Int) throws -> JSONValue {
            var object: [String: JSONValue] = [:]
            while let line = current, line.indent == indent, !isSequenceItem(line.text) {
                guard let (key, rest) = MiniYAML.splitKey(line.text) else {
                    throw ParseError(line: line.number, message: "需要 “键: 值”")
                }
                position += 1
                if rest.isEmpty {
                    if let next = current, next.indent > indent {
                        object[key] = try parseNode(indent: next.indent)
                    } else if let next = current, next.indent == indent, isSequenceItem(next.text) {
                        object[key] = try parseSequence(indent: indent)
                    } else {
                        object[key] = .null
                    }
                } else if rest == "|" || rest == ">" || rest.hasPrefix("|") || rest.hasPrefix(">") {
                    object[key] = .string(blockScalar(parentIndent: indent, folded: rest.hasPrefix(">")))
                } else {
                    object[key] = try value(from: rest, line: line)
                }
            }
            return .object(object)
        }

        mutating func blockScalar(parentIndent: Int, folded: Bool) -> String {
            var parts: [String] = []
            while let line = current, line.indent > parentIndent {
                parts.append(line.text)
                position += 1
            }
            return parts.joined(separator: folded ? " " : "\n")
        }

        /// A scalar or flow collection; a flow collection may continue on the following lines.
        mutating func value(from text: String, line: Line) throws -> JSONValue {
            var text = text
            if text.hasPrefix("{") || text.hasPrefix("[") {
                while !MiniYAML.isBalanced(text), let next = current {
                    text += " " + next.text
                    position += 1
                }
                var flow = FlowParser(Array(text), line: line.number)
                return try flow.parseValue()
            }
            return MiniYAML.scalar(text)
        }
    }

    // MARK: Keys and scalars

    /// Splits "key: value" (or "key:"), honouring quoted keys.
    static func splitKey(_ text: String) -> (String, String)? {
        let characters = Array(text)
        var index = 0
        var key: String
        if let first = characters.first, first == "\"" || first == "'" {
            guard let (quoted, end) = readQuoted(characters, from: 0) else { return nil }
            key = quoted
            index = end
            while index < characters.count, characters[index] == " " { index += 1 }
            guard index < characters.count, characters[index] == ":" else { return nil }
        } else {
            if text.hasPrefix("{") || text.hasPrefix("[") { return nil }
            while index < characters.count {
                if characters[index] == ":", index + 1 == characters.count || characters[index + 1] == " " { break }
                index += 1
            }
            guard index < characters.count else { return nil }
            key = String(characters[0..<index]).trimmingCharacters(in: .whitespaces)
            if key.isEmpty { return nil }
        }
        let rest = String(characters[(index + 1)...]).trimmingCharacters(in: .whitespaces)
        return (key, rest)
    }

    static func readQuoted(_ characters: [Character], from start: Int) -> (String, Int)? {
        let quote = characters[start]
        var index = start + 1
        var result = ""
        while index < characters.count {
            let character = characters[index]
            if quote == "'" {
                if character == "'" {
                    if index + 1 < characters.count, characters[index + 1] == "'" { result.append("'"); index += 2; continue }
                    return (result, index + 1)
                }
                result.append(character)
            } else {
                if character == "\"" { return (result, index + 1) }
                if character == "\\", index + 1 < characters.count {
                    index += 1
                    switch characters[index] {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    case "r": result.append("\r")
                    case "0": result.append("\0")
                    case "u" where index + 4 < characters.count:
                        let hex = String(characters[(index + 1)...(index + 4)])
                        if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) { result.append(Character(scalar)) }
                        index += 4
                    default: result.append(characters[index])
                    }
                } else {
                    result.append(character)
                }
            }
            index += 1
        }
        return nil
    }

    /// A plain or quoted scalar. Numbers become ints only when that loses nothing
    /// ("0123", "+1" and "1.10" stay strings, so passwords survive).
    static func scalar(_ text: String) -> JSONValue {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let characters = Array(trimmed)
        if let first = characters.first, first == "\"" || first == "'", let (value, _) = readQuoted(characters, from: 0) {
            return .string(value)
        }
        switch trimmed {
        case "true", "True", "TRUE": return .bool(true)
        case "false", "False", "FALSE": return .bool(false)
        case "null", "Null", "NULL", "~", "": return .null
        default: break
        }
        if let int = Int(trimmed), String(int) == trimmed { return .int(int) }
        // Decimals stay strings: "1.10" as a password must not become 1.1.
        return .string(trimmed)
    }

    static func isBalanced(_ text: String) -> Bool {
        var depth = 0
        var quote: Character?
        var escaped = false
        for character in text {
            if let open = quote {
                if escaped { escaped = false; continue }
                if character == "\\", open == "\"" { escaped = true; continue }
                if character == open { quote = nil }
                continue
            }
            switch character {
            case "\"", "'": quote = character
            case "{", "[": depth += 1
            case "}", "]": depth -= 1
            default: break
            }
        }
        return depth <= 0
    }

    // MARK: Flow collections

    struct FlowParser {
        let characters: [Character]
        let line: Int
        var index = 0

        init(_ characters: [Character], line: Int) {
            self.characters = characters
            self.line = line
        }

        mutating func skipSpaces() {
            while index < characters.count, characters[index] == " " || characters[index] == "\n" { index += 1 }
        }

        mutating func parseValue() throws -> JSONValue {
            skipSpaces()
            guard index < characters.count else { return .null }
            switch characters[index] {
            case "{": return try parseObject()
            case "[": return try parseArray()
            case "\"", "'":
                guard let (value, end) = MiniYAML.readQuoted(characters, from: index) else {
                    throw ParseError(line: line, message: "引号未闭合")
                }
                index = end
                return .string(value)
            default:
                return MiniYAML.scalar(readPlain(isKey: false))
            }
        }

        /// Reads up to `,` `}` `]` (and, for keys, `:` followed by a space or delimiter).
        mutating func readPlain(isKey: Bool) -> String {
            let start = index
            while index < characters.count {
                let character = characters[index]
                if character == "," || character == "}" || character == "]" { break }
                if isKey, character == ":" {
                    let next = index + 1 < characters.count ? characters[index + 1] : " "
                    if next == " " || next == "," || next == "}" || next == "\"" || next == "'" { break }
                }
                index += 1
            }
            return String(characters[start..<index]).trimmingCharacters(in: .whitespaces)
        }

        mutating func parseObject() throws -> JSONValue {
            index += 1 // {
            var object: [String: JSONValue] = [:]
            while true {
                skipSpaces()
                guard index < characters.count else { throw ParseError(line: line, message: "缺少 }") }
                if characters[index] == "}" { index += 1; break }
                if characters[index] == "," { index += 1; continue }
                let key: String
                if characters[index] == "\"" || characters[index] == "'" {
                    guard let (quoted, end) = MiniYAML.readQuoted(characters, from: index) else {
                        throw ParseError(line: line, message: "引号未闭合")
                    }
                    key = quoted
                    index = end
                } else {
                    key = readPlain(isKey: true)
                }
                skipSpaces()
                if index < characters.count, characters[index] == ":" {
                    index += 1
                    skipSpaces()
                    if index < characters.count, characters[index] == "," || characters[index] == "}" {
                        object[key] = .null
                    } else {
                        object[key] = try parseValue()
                    }
                } else {
                    object[key] = .null
                }
            }
            return .object(object)
        }

        mutating func parseArray() throws -> JSONValue {
            index += 1 // [
            var items: [JSONValue] = []
            while true {
                skipSpaces()
                guard index < characters.count else { throw ParseError(line: line, message: "缺少 ]") }
                if characters[index] == "]" { index += 1; break }
                if characters[index] == "," { index += 1; continue }
                items.append(try parseValue())
            }
            return .array(items)
        }
    }
}
