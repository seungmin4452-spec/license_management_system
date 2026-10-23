import Foundation

/// JSON 숫자. 원문 표기를 보존한다(정수/실수 구분, 1과 1.0 구분이 필요한 곳이 있음).
public struct JSONNumber: Equatable, Sendable {
    public let raw: String

    public init(raw: String) { self.raw = raw }
    public init(_ value: Int) { self.raw = String(value) }

    /// 소수점·지수가 없는 정수 표기인지
    public var isIntegerLiteral: Bool {
        !raw.contains(".") && !raw.contains("e") && !raw.contains("E")
    }

    public var doubleValue: Double { Double(raw) ?? .nan }

    /// 정수 표기이고 Int 범위면 값
    public var intValue: Int? { isIntegerLiteral ? Int(raw) : nil }
}

/// 키 순서를 보존하는 JSON 객체. 같은 키가 여러 번 나오면 처음 위치에 마지막 값을 둔다(JavaScript·Python과 같음).
public struct JSONObject: Equatable, Sendable {
    public private(set) var entries: [(key: String, value: JSONValue)] = []

    public init() {}

    public init(_ pairs: [(String, JSONValue)]) {
        for (k, v) in pairs { self[k] = v }
    }

    public var keys: [String] { entries.map(\.key) }
    public var count: Int { entries.count }

    public subscript(key: String) -> JSONValue? {
        get { entries.first(where: { $0.key == key })?.value }
        set {
            if let i = entries.firstIndex(where: { $0.key == key }) {
                if let newValue { entries[i].value = newValue } else { entries.remove(at: i) }
            } else if let newValue {
                entries.append((key, newValue))
            }
        }
    }

    /// 키 집합이 정확히 `expected` 와 같은지
    public func hasExactly(_ expected: Set<String>) -> Bool {
        Set(keys) == expected && keys.count == expected.count
    }

    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
        guard lhs.entries.count == rhs.entries.count else { return false }
        return zip(lhs.entries, rhs.entries).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    }
}

public indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(JSONNumber)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var objectValue: JSONObject? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var numberValue: JSONNumber? {
        if case .number(let n) = self { return n }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public static func str(_ s: String?) -> JSONValue {
        s.map { .string($0) } ?? .null
    }
}
