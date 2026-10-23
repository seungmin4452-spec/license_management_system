import Foundation

/// 정규식 대신 코드 포인트 단위로 직접 검사한다(언어별 정규식 차이, Swift 문자 클러스터 계산을 피함).
public enum TextRules {
    public static func isUpper(_ v: UInt32) -> Bool { (0x41...0x5A).contains(v) }
    public static func isLower(_ v: UInt32) -> Bool { (0x61...0x7A).contains(v) }
    public static func isDigit(_ v: UInt32) -> Bool { (0x30...0x39).contains(v) }
    public static func isHexLower(_ v: UInt32) -> Bool { isDigit(v) || (0x61...0x66).contains(v) }

    /// 코드 포인트 수(Python `len` 과 같음, Swift `String.count` 와 다름)
    public static func length(_ s: String) -> Int { s.unicodeScalars.count }

    /// 제어 문자(U+0000–U+001F, U+007F) 포함 여부
    public static func hasControl(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value <= 0x1F || $0.value == 0x7F }
    }

    /// 규격 3절: licensee 처음·끝에 올 수 없는 공백 문자
    public static let edgeSpaces: Set<UInt32> = [
        0x20, 0x85, 0xA0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007,
        0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF,
    ]

    public static func hasEdgeSpace(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, let last = s.unicodeScalars.last else { return false }
        return edgeSpaces.contains(first.value) || edgeSpaces.contains(last.value)
    }

    /// 앞뒤의 규격 공백 문자와 탭·줄바꿈을 제거한다(발급 입력 정리용).
    public static func stripEdge(_ s: String) -> String {
        let strip: (Unicode.Scalar) -> Bool = { edgeSpaces.contains($0.value) || (0x09...0x0D).contains($0.value) }
        var scalars = Array(s.unicodeScalars)
        while let f = scalars.first, strip(f) { scalars.removeFirst() }
        while let l = scalars.last, strip(l) { scalars.removeLast() }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    /// `^[A-Z2-7]{n}$`
    public static func isBase32(_ s: String, length n: Int) -> Bool {
        let u = s.unicodeScalars
        return u.count == n && u.allSatisfy { isUpper($0.value) || (0x32...0x37).contains($0.value) }
    }

    /// `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`
    public static func isLowerUUID(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        return parts.allSatisfy { $0.unicodeScalars.allSatisfy { isHexLower($0.value) } }
    }

    /// `^[A-Z][A-Z0-9_]{1,31}$`
    public static func isV1ProductCode(_ s: String) -> Bool {
        let u = Array(s.unicodeScalars)
        guard (2...32).contains(u.count), isUpper(u[0].value) else { return false }
        return u.dropFirst().allSatisfy { isUpper($0.value) || isDigit($0.value) || $0 == "_" }
    }

    /// `^[a-z0-9][a-z0-9._-]{0,63}$`
    public static func isKeyId(_ s: String) -> Bool {
        let u = Array(s.unicodeScalars)
        guard (1...64).contains(u.count) else { return false }
        guard isLower(u[0].value) || isDigit(u[0].value) else { return false }
        return u.dropFirst().allSatisfy { isLower($0.value) || isDigit($0.value) || $0 == "." || $0 == "_" || $0 == "-" }
    }

    /// `^[a-z][a-z0-9_-]{0,31}$`
    public static func isEdition(_ s: String) -> Bool {
        let u = Array(s.unicodeScalars)
        guard (1...32).contains(u.count), isLower(u[0].value) else { return false }
        return u.dropFirst().allSatisfy { isLower($0.value) || isDigit($0.value) || $0 == "_" || $0 == "-" }
    }

    /// `^[a-z][a-z0-9_]{0,31}$`
    public static func isOptionKey(_ s: String) -> Bool {
        let u = Array(s.unicodeScalars)
        guard (1...32).contains(u.count), isLower(u[0].value) else { return false }
        return u.dropFirst().allSatisfy { isLower($0.value) || isDigit($0.value) || $0 == "_" }
    }

    /// `0|[1-9][0-9]{0,3}`
    private static func versionPart(_ s: Substring) -> Int? {
        let u = Array(s.unicodeScalars)
        guard (1...4).contains(u.count), u.allSatisfy({ isDigit($0.value) }) else { return nil }
        if u.count > 1 && u[0] == "0" { return nil }
        return Int(String(s))
    }

    /// `주.부` → (주, 부). 형식이 다르면 nil
    public static func parseSeries(_ s: String) -> (Int, Int)? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let a = versionPart(parts[0]), let b = versionPart(parts[1]) else { return nil }
        return (a, b)
    }

    /// `주.부.수` → (주, 부, 수). 형식이 다르면 nil
    public static func parseAppVersion(_ s: String) -> (Int, Int, Int)? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let a = versionPart(parts[0]), let b = versionPart(parts[1]),
              let c = versionPart(parts[2]) else { return nil }
        return (a, b, c)
    }

    /// 표준 Base64 엄격 디코딩: 알파벳·패딩 검사 후, 다시 인코딩한 값이 원문과 같아야 한다.
    public static func strictBase64(_ s: String) -> Data? {
        let u = Array(s.unicodeScalars)
        guard !u.isEmpty else { return nil }
        var pad = 0
        for (i, c) in u.enumerated() {
            let v = c.value
            if c == "=" {
                pad += 1
                continue
            }
            if pad > 0 { return nil } // 패딩 뒤에 문자가 있음
            guard isUpper(v) || isLower(v) || isDigit(v) || c == "+" || c == "/" else { return nil }
            _ = i
        }
        guard pad <= 2, let data = Data(base64Encoded: s), data.base64EncodedString() == s else { return nil }
        return data
    }

    public static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public static func dataFromHex(_ s: String) -> Data? {
        let chars = Array(s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().unicodeScalars)
        guard chars.count % 2 == 0, !chars.isEmpty else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = hexValue(chars[i]), let lo = hexValue(chars[i + 1]) else { return nil }
            out.append(UInt8(hi << 4 | lo))
            i += 2
        }
        return out
    }

    private static func hexValue(_ c: Unicode.Scalar) -> UInt32? {
        switch c.value {
        case 0x30...0x39: return c.value - 0x30
        case 0x61...0x66: return c.value - 0x61 + 10
        default: return nil
        }
    }
}
