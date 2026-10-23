import Foundation

public enum JSONWriteError: Error, Equatable {
    /// 정규화 JSON에서 표현 방식이 언어마다 다른 숫자(실수·지수·큰 정수)
    case unsupportedNumber(String)
}

/// JSON 직렬화. Swift `JSONEncoder` 는 `/` 를 `\/` 로 바꾸는 등 서명 대상 바이트가 달라지므로 쓰지 않는다.
///
/// 문자열 이스케이프 규칙(규격 `docs/license-format-v1.md` 4절):
/// `"` → `\"`, `\` → `\\`, U+0008 `\b`, U+0009 `\t`, U+000A `\n`, U+000C `\f`, U+000D `\r`,
/// 그 밖의 U+0000–U+001F → `\u00xx`(소문자 16진). 그 외 모든 문자(한글, `/`, U+007F 포함)는 그대로.
/// 이 규칙은 JavaScript `JSON.stringify` 와 Python `json.dumps(ensure_ascii=False)` 가 만드는 결과와 같다.
public enum JSONWriter {
    // MARK: - 정규화(서명 대상)

    /// 키를 유니코드 코드 포인트 순으로 정렬하고 공백 없이 직렬화한다.
    /// 숫자는 부호 있는 정수 표기만 허용한다(JavaScript 안전 정수 범위). 그 밖의 숫자는 오류.
    public static func canonical(_ value: JSONValue) throws -> String {
        var out = ""
        try writeCanonical(value, into: &out)
        return out
    }

    public static func canonicalData(_ value: JSONValue) throws -> Data {
        Data(try canonical(value).utf8)
    }

    private static func writeCanonical(_ value: JSONValue, into out: inout String) throws {
        switch value {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += try canonicalNumber(n)
        case .string(let s): writeString(s, into: &out)
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                try writeCanonical(item, into: &out)
            }
            out += "]"
        case .object(let obj):
            out += "{"
            let sorted = obj.entries.sorted { codePointLess($0.key, $1.key) }
            for (i, entry) in sorted.enumerated() {
                if i > 0 { out += "," }
                writeString(entry.key, into: &out)
                out += ":"
                try writeCanonical(entry.value, into: &out)
            }
            out += "}"
        }
    }

    private static func canonicalNumber(_ n: JSONNumber) throws -> String {
        // 정수 원문만 허용. "-0" 은 언어마다 결과가 달라 거부한다.
        guard n.isIntegerLiteral, let v = Int(n.raw), n.raw != "-0", abs(v) <= 9_007_199_254_740_991 else {
            throw JSONWriteError.unsupportedNumber(n.raw)
        }
        return String(v)
    }

    /// 유니코드 코드 포인트 순 비교. (Swift `String <` 은 정규화 동등성을 쓰므로 사용하지 않는다.)
    public static func codePointLess(_ a: String, _ b: String) -> Bool {
        var ia = a.unicodeScalars.makeIterator()
        var ib = b.unicodeScalars.makeIterator()
        while true {
            switch (ia.next(), ib.next()) {
            case (nil, nil): return false
            case (nil, _): return true
            case (_, nil): return false
            case let (x?, y?):
                if x.value != y.value { return x.value < y.value }
            }
        }
    }

    public static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x09: out += "\\t"
            case 0x0A: out += "\\n"
            case 0x0C: out += "\\f"
            case 0x0D: out += "\\r"
            case 0x00...0x1F:
                let hex = String(scalar.value, radix: 16, uppercase: false)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }

    public static func quoted(_ s: String) -> String {
        var out = ""
        writeString(s, into: &out)
        return out
    }

    // MARK: - 들여쓰기 2칸 (파일 저장용)

    /// 키 순서를 그대로 두고 들여쓰기 2칸으로 직렬화한다.
    /// JavaScript `JSON.stringify(v, null, 2)` 와 Python `json.dumps(v, ensure_ascii=False, indent=2)` 결과와 같다
    /// (이 프로그램이 쓰는 값 종류: 문자열·정수·null·객체).
    public static func pretty(_ value: JSONValue) -> String {
        var out = ""
        writePretty(value, indent: 0, into: &out)
        return out
    }

    private static func writePretty(_ value: JSONValue, indent: Int, into out: inout String) {
        switch value {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n.raw
        case .string(let s): writeString(s, into: &out)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "[\n"
            for (i, item) in items.enumerated() {
                out += String(repeating: " ", count: indent + 2)
                writePretty(item, indent: indent + 2, into: &out)
                out += i < items.count - 1 ? ",\n" : "\n"
            }
            out += String(repeating: " ", count: indent) + "]"
        case .object(let obj):
            if obj.entries.isEmpty { out += "{}"; return }
            out += "{\n"
            for (i, entry) in obj.entries.enumerated() {
                out += String(repeating: " ", count: indent + 2)
                writeString(entry.key, into: &out)
                out += ": "
                writePretty(entry.value, indent: indent + 2, into: &out)
                out += i < obj.entries.count - 1 ? ",\n" : "\n"
            }
            out += String(repeating: " ", count: indent) + "}"
        }
    }
}
