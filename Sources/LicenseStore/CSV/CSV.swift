import Foundation

/// UTF-8 CSV(RFC 4180). 첫 줄은 머리글.
public struct CSVTable: Equatable {
    public var header: [String]
    public var rows: [[String]]

    public init(header: [String], rows: [[String]]) {
        self.header = header
        self.rows = rows
    }

    public func value(_ row: [String], _ column: Int?) -> String {
        guard let c = column, c >= 0, c < row.count else { return "" }
        return row[c]
    }
}

public enum CSVError: Error, LocalizedError, Equatable {
    case notUTF8
    case unterminatedQuote(line: Int)
    case empty

    public var errorDescription: String? {
        switch self {
        case .notUTF8: return "CSV 파일이 UTF-8이 아닙니다. 엑셀에서 'CSV UTF-8'로 저장하세요."
        case .unterminatedQuote(let line): return "\(line)번째 줄 근처에서 따옴표가 닫히지 않았습니다."
        case .empty: return "CSV 파일에 머리글이 없습니다."
        }
    }
}

public enum CSV {
    /// 수식 실행 위험이 있는 첫 글자
    static let formulaLeads: Set<Character> = ["=", "+", "-", "@", "\t", "\r"]

    // MARK: 읽기

    public static func parse(_ data: Data) throws -> CSVTable {
        guard var text = String(data: data, encoding: .utf8) else { throw CSVError.notUTF8 }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let records = try parseRecords(text)
        guard let header = records.first else { throw CSVError.empty }
        let rows = records.dropFirst().filter { !($0.count == 1 && $0[0].isEmpty) } // 빈 줄 제외
        return CSVTable(header: header.map { $0.trimmingCharacters(in: .whitespaces) }, rows: Array(rows).map(unescapeRow))
    }

    static func parseRecords(_ text: String) throws -> [[String]] {
        var records: [[String]] = []
        var field = ""
        var record: [String] = []
        var inQuotes = false
        var line = 1
        var chars = Array(text)
        chars.append("\n") // 마지막 줄 처리
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    if c == "\n" || c == "\r\n" { line += 1 }
                    field.append(c)
                }
            } else {
                switch c {
                case "\"" where field.isEmpty:
                    inQuotes = true
                case ",":
                    record.append(field)
                    field = ""
                case "\n", "\r\n", "\r":
                    record.append(field)
                    field = ""
                    records.append(record)
                    record = []
                    line += 1
                default:
                    field.append(c)
                }
            }
            i += 1
        }
        if inQuotes { throw CSVError.unterminatedQuote(line: line) }
        // 끝에 덧붙인 줄바꿈으로 생긴 빈 레코드 제거
        if let last = records.last, last == [""] { records.removeLast() }
        return records
    }

    /// 내보내기에서 붙인 보호용 작은따옴표를 되돌린다(`'=...` → `=...`).
    static func unescapeRow(_ row: [String]) -> [String] {
        row.map { cell in
            if cell.count >= 2, cell.first == "'", let second = cell.dropFirst().first, formulaLeads.contains(second) {
                return String(cell.dropFirst())
            }
            return cell
        }
    }

    // MARK: 쓰기

    /// 셀 하나. 수식 실행 위험(= + - @ 탭 CR로 시작)이 있으면 앞에 작은따옴표를 붙인다.
    /// 쉼표·따옴표·줄바꿈이 있으면 큰따옴표로 감싼다. 값(앞자리 0, 한글)은 그대로 둔다.
    public static func cell(_ value: String) -> String {
        var v = value
        if let first = v.first, formulaLeads.contains(first) { v = "'" + v }
        if v.contains(",") || v.contains("\"") || v.contains("\n") || v.contains("\r") || v.hasPrefix(" ") || v.hasSuffix(" ") {
            v = "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return v
    }

    /// UTF-8 BOM + CRLF (엑셀 호환)
    public static func write(header: [String], rows: [[String]]) -> Data {
        var out = "\u{FEFF}"
        out += header.map(cell).joined(separator: ",") + "\r\n"
        for r in rows { out += r.map(cell).joined(separator: ",") + "\r\n" }
        return Data(out.utf8)
    }
}
