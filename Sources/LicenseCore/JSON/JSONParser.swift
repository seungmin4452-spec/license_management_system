import Foundation

public enum JSONParseError: Error, Equatable {
    case invalidUTF8
    case syntax(offset: Int)
    case loneSurrogate
    case tooDeep
}

/// RFC 8259 JSON 파서. Foundation `JSONSerialization` 대신 직접 구현한 이유:
/// - 숫자 원문(1과 1.0)과 객체 키 순서를 보존해야 한다.
/// - 서명 검증용 정규화 JSON을 원래 값 그대로 다시 만들어야 한다.
public enum JSONParser {
    public static func parse(_ data: Data) throws -> JSONValue {
        guard let text = String(data: data, encoding: .utf8) else { throw JSONParseError.invalidUTF8 }
        return try parse(text)
    }

    public static func parse(_ text: String) throws -> JSONValue {
        var p = Parser(scalars: Array(text.unicodeScalars))
        p.skipWhitespace()
        let value = try p.parseValue(depth: 0)
        p.skipWhitespace()
        guard p.index == p.scalars.count else { throw JSONParseError.syntax(offset: p.index) }
        return value
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0

        init(scalars: [Unicode.Scalar]) {
            // UTF-8 BOM은 JSON 텍스트의 일부가 아니다. 파일 앞 BOM은 허용하지 않는다(JSON.parse·json.loads와 동일하게 오류).
            self.scalars = scalars
        }

        mutating func skipWhitespace() {
            while index < scalars.count {
                switch scalars[index] {
                case " ", "\t", "\n", "\r": index += 1
                default: return
                }
            }
        }

        func peek() -> Unicode.Scalar? { index < scalars.count ? scalars[index] : nil }

        mutating func expect(_ s: String) throws {
            for c in s.unicodeScalars {
                guard peek() == c else { throw JSONParseError.syntax(offset: index) }
                index += 1
            }
        }

        mutating func parseValue(depth: Int) throws -> JSONValue {
            guard depth < 64 else { throw JSONParseError.tooDeep }
            guard let c = peek() else { throw JSONParseError.syntax(offset: index) }
            switch c {
            case "{": return .object(try parseObject(depth: depth))
            case "[": return .array(try parseArray(depth: depth))
            case "\"": return .string(try parseString())
            case "t": try expect("true"); return .bool(true)
            case "f": try expect("false"); return .bool(false)
            case "n": try expect("null"); return .null
            default:
                if c == "-" || ("0"..."9").contains(c) { return .number(try parseNumber()) }
                throw JSONParseError.syntax(offset: index)
            }
        }

        mutating func parseObject(depth: Int) throws -> JSONObject {
            index += 1 // {
            var obj = JSONObject()
            skipWhitespace()
            if peek() == "}" { index += 1; return obj }
            while true {
                skipWhitespace()
                guard peek() == "\"" else { throw JSONParseError.syntax(offset: index) }
                let key = try parseString()
                skipWhitespace()
                try expect(":")
                skipWhitespace()
                let value = try parseValue(depth: depth + 1)
                obj[key] = value
                skipWhitespace()
                if peek() == "," { index += 1; continue }
                if peek() == "}" { index += 1; return obj }
                throw JSONParseError.syntax(offset: index)
            }
        }

        mutating func parseArray(depth: Int) throws -> [JSONValue] {
            index += 1 // [
            var arr: [JSONValue] = []
            skipWhitespace()
            if peek() == "]" { index += 1; return arr }
            while true {
                skipWhitespace()
                arr.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                if peek() == "," { index += 1; continue }
                if peek() == "]" { index += 1; return arr }
                throw JSONParseError.syntax(offset: index)
            }
        }

        mutating func parseHex4() throws -> UInt32 {
            guard index + 4 <= scalars.count else { throw JSONParseError.syntax(offset: index) }
            var v: UInt32 = 0
            for _ in 0..<4 {
                let c = scalars[index]
                let d: UInt32
                switch c.value {
                case 0x30...0x39: d = c.value - 0x30
                case 0x41...0x46: d = c.value - 0x41 + 10
                case 0x61...0x66: d = c.value - 0x61 + 10
                default: throw JSONParseError.syntax(offset: index)
                }
                v = v * 16 + d
                index += 1
            }
            return v
        }

        mutating func parseString() throws -> String {
            index += 1 // "
            var out = String.UnicodeScalarView()
            while true {
                guard let c = peek() else { throw JSONParseError.syntax(offset: index) }
                index += 1
                if c == "\"" { return String(out) }
                if c.value < 0x20 { throw JSONParseError.syntax(offset: index - 1) }
                if c != "\\" { out.append(c); continue }
                guard let e = peek() else { throw JSONParseError.syntax(offset: index) }
                index += 1
                switch e {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/": out.append("/")
                case "b": out.append(Unicode.Scalar(UInt8(0x08)))
                case "f": out.append(Unicode.Scalar(UInt8(0x0C)))
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "u":
                    let first = try parseHex4()
                    if (0xD800...0xDBFF).contains(first) {
                        // 짝이 되는 하위 서로게이트가 반드시 이어져야 한다
                        guard index + 6 <= scalars.count, scalars[index] == "\\", scalars[index + 1] == "u" else {
                            throw JSONParseError.loneSurrogate
                        }
                        index += 2
                        let second = try parseHex4()
                        guard (0xDC00...0xDFFF).contains(second) else { throw JSONParseError.loneSurrogate }
                        let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                        guard let s = Unicode.Scalar(combined) else { throw JSONParseError.loneSurrogate }
                        out.append(s)
                    } else if (0xDC00...0xDFFF).contains(first) {
                        throw JSONParseError.loneSurrogate
                    } else {
                        guard let s = Unicode.Scalar(first) else { throw JSONParseError.syntax(offset: index) }
                        out.append(s)
                    }
                default:
                    throw JSONParseError.syntax(offset: index - 1)
                }
            }
        }

        mutating func parseNumber() throws -> JSONNumber {
            let start = index
            func isDigit(_ s: Unicode.Scalar?) -> Bool { s.map { ("0"..."9").contains($0) } ?? false }
            if peek() == "-" { index += 1 }
            if peek() == "0" {
                index += 1
            } else if isDigit(peek()) {
                while isDigit(peek()) { index += 1 }
            } else {
                throw JSONParseError.syntax(offset: index)
            }
            if peek() == "." {
                index += 1
                guard isDigit(peek()) else { throw JSONParseError.syntax(offset: index) }
                while isDigit(peek()) { index += 1 }
            }
            if peek() == "e" || peek() == "E" {
                index += 1
                if peek() == "+" || peek() == "-" { index += 1 }
                guard isDigit(peek()) else { throw JSONParseError.syntax(offset: index) }
                while isDigit(peek()) { index += 1 }
            }
            var raw = String.UnicodeScalarView()
            raw.append(contentsOf: scalars[start..<index])
            return JSONNumber(raw: String(raw))
        }
    }
}
