import Foundation

/// 서울 날짜(연·월·일). 시각 없음.
public struct CivilDate: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// `YYYY-MM-DD` 형식, 실제로 있는 날짜만
    public init?(string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.unicodeScalars.allSatisfy { TextRules.isDigit($0.value) } }),
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              LicenseTime.isValidDate(year: y, month: m, day: d) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func < (a: CivilDate, b: CivilDate) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    /// 1970-01-01부터 날 수
    public var dayNumber: Int { LicenseTime.daysFromCivil(year, month, day) }

    public init(dayNumber: Int) {
        let (y, m, d) = LicenseTime.civilFromDays(dayNumber)
        self.init(year: y, month: m, day: d)
    }

    public func adding(days: Int) -> CivilDate { CivilDate(dayNumber: dayNumber + days) }

    /// 같은 날짜로 N개월 뒤. 그 달에 같은 날이 없으면 말일(예: 1월 31일 + 1개월 → 2월 말일).
    public func adding(months: Int) -> CivilDate {
        let index = (month - 1) + months
        let y = year + Int(floor(Double(index) / 12.0))
        let m = ((index % 12) + 12) % 12 + 1
        return CivilDate(year: y, month: m, day: min(day, LicenseTime.daysInMonth(year: y, month: m)))
    }
}

/// 시각 처리 규칙
/// - DB와 라이선스 파일의 시각: UTC `YYYY-MM-DDTHH:MM:SSZ`(초 단위). 문자열 정렬 = 시간 순서.
/// - 화면 입력·표시: Asia/Seoul. 한국은 1988년 이후 일광절약시간이 없어 UTC+9 고정으로 계산한다.
/// - 기간: `[시작, 만료)` — 만료 시각 정각부터 만료.
/// - 날짜 단위 기간: 시작일 서울 00:00 ~ 마지막 사용일 **다음 날** 서울 00:00(미포함).
public enum LicenseTime {
    public static let seoulOffsetSeconds = 9 * 3600

    public static func isLeap(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }

    public static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2: return isLeap(year) ? 29 : 28
        default: return 0
        }
    }

    public static func isValidDate(year: Int, month: Int, day: Int) -> Bool {
        (1...9999).contains(year) && (1...12).contains(month) && day >= 1 && day <= daysInMonth(year: year, month: month)
    }

    // Howard Hinnant의 날짜 알고리즘(그레고리력, 1970-01-01 = 0)
    public static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = month > 2 ? month - 3 : month + 9
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    public static func civilFromDays(_ days: Int) -> (Int, Int, Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        return (y, m, d)
    }

    /// 초 단위 내림한 epoch 초
    public static func epochSeconds(_ date: Date) -> Int {
        Int(floor(date.timeIntervalSince1970))
    }

    public static func date(epochSeconds: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(epochSeconds))
    }

    /// 초 미만 버림
    public static func truncated(_ date: Date) -> Date {
        Self.date(epochSeconds: epochSeconds(date))
    }

    private static func parts(epochSeconds s: Int) -> (CivilDate, Int, Int, Int) {
        let days = Int(floor(Double(s) / 86_400.0))
        let rem = s - days * 86_400
        return (CivilDate(dayNumber: days), rem / 3600, (rem % 3600) / 60, rem % 60)
    }

    /// UTC `YYYY-MM-DDTHH:MM:SSZ`
    public static func utcString(_ date: Date) -> String {
        let (d, h, m, s) = parts(epochSeconds: epochSeconds(date))
        return String(format: "%@T%02d:%02d:%02dZ", d.description, h, m, s)
    }

    /// UTC `YYYY-MM-DDTHH:MM:SS.sssZ` (JavaScript `toISOString()` 과 같은 형식)
    public static func utcMillisString(_ date: Date) -> String {
        let ms = Int(floor(date.timeIntervalSince1970 * 1000))
        let secs = Int(floor(Double(ms) / 1000.0))
        let frac = ms - secs * 1000
        let (d, h, m, s) = parts(epochSeconds: secs)
        return String(format: "%@T%02d:%02d:%02d.%03dZ", d.description, h, m, s, frac)
    }

    /// 엄격한 UTC `YYYY-MM-DDTHH:MM:SSZ` 해석. 0001–9999년, 실제로 있는 날짜·시각만.
    public static func parseUTC(_ s: String) -> Date? {
        let u = Array(s.unicodeScalars)
        guard u.count == 20 else { return nil }
        let digitIdx = [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18]
        guard digitIdx.allSatisfy({ TextRules.isDigit(u[$0].value) }),
              u[4] == "-", u[7] == "-", u[10] == "T", u[13] == ":", u[16] == ":", u[19] == "Z" else { return nil }
        func num(_ a: Int, _ b: Int) -> Int { Int(String(String.UnicodeScalarView(u[a..<b])))! }
        let (y, mo, d, h, mi, se) = (num(0, 4), num(5, 7), num(8, 10), num(11, 13), num(14, 16), num(17, 19))
        guard isValidDate(year: y, month: mo, day: d), h < 24, mi < 60, se < 60 else { return nil }
        let days = daysFromCivil(y, mo, d)
        return date(epochSeconds: days * 86_400 + h * 3600 + mi * 60 + se)
    }

    /// 밀리초가 붙은 UTC 시각(`...SS.sssZ`)도 받아들인다(ReviewCut 이전 형식 `issuedAt`).
    public static func parseUTCMillis(_ s: String) -> Date? {
        if let d = parseUTC(s) { return d }
        let u = Array(s.unicodeScalars)
        guard u.count == 24, u[19] == ".", u[23] == "Z",
              (20...22).allSatisfy({ TextRules.isDigit(u[$0].value) }) else { return nil }
        let head = String(String.UnicodeScalarView(u[0..<19])) + "Z"
        guard let base = parseUTC(head), let ms = Int(String(String.UnicodeScalarView(u[20..<23]))) else { return nil }
        return base.addingTimeInterval(Double(ms) / 1000.0)
    }

    // MARK: - 서울 기준

    /// 그 시각의 서울 날짜
    public static func seoulDate(of date: Date) -> CivilDate {
        let s = epochSeconds(date) + seoulOffsetSeconds
        return CivilDate(dayNumber: Int(floor(Double(s) / 86_400.0)))
    }

    /// 서울 날짜 00:00:00 의 실제 시각
    public static func seoulMidnight(_ day: CivilDate) -> Date {
        date(epochSeconds: day.dayNumber * 86_400 - seoulOffsetSeconds)
    }

    /// 마지막 사용일(서울) → 만료 시각(다음 날 서울 00:00, 미포함)
    public static func endExclusive(lastDay: CivilDate) -> Date {
        seoulMidnight(lastDay.adding(days: 1))
    }

    /// 만료 시각(미포함) → 사용할 수 있는 마지막 서울 날짜. 이전 형식(23:59:59)과 v1(다음 날 00:00) 모두 같은 날짜.
    public static func lastUseDay(expiresAt: Date) -> CivilDate {
        seoulDate(of: expiresAt.addingTimeInterval(-1))
    }

    /// 서울 날짜·시각 문자열 `YYYY-MM-DD HH:MM`
    public static func seoulDisplay(_ date: Date, seconds: Bool = false) -> String {
        let s = epochSeconds(date) + seoulOffsetSeconds
        let (d, h, m, sec) = parts(epochSeconds: s)
        return seconds
            ? String(format: "%@ %02d:%02d:%02d", d.description, h, m, sec)
            : String(format: "%@ %02d:%02d", d.description, h, m)
    }

    /// 서울 날짜 + 시·분 → 시각
    public static func seoulDateTime(_ day: CivilDate, hour: Int, minute: Int, second: Int = 0) -> Date {
        date(epochSeconds: day.dayNumber * 86_400 + hour * 3600 + minute * 60 + second - seoulOffsetSeconds)
    }

    /// 기간 계산: 시작일부터 N개월(기존 발급 도구 규칙 — 시작일 + N개월 같은 날짜가 마지막 사용일)
    public static func lastDay(start: CivilDate, months: Int) -> CivilDate {
        start.adding(months: months)
    }
}
