import CryptoKit
import Foundation
import GRDB
import LicenseCore

/// 가져오기 대상 필드(라이선스 기록 단위)
public enum ImportField: String, CaseIterable, Identifiable {
    case managementRef = "management_ref"
    case customerId = "customer_id"
    case customerName = "customer_name"
    case customerContact = "customer_contact"
    case productCode = "product_code"
    case pcScheme = "pc_scheme"
    case pcNumber = "pc_number"
    case pcAlias = "pc_alias"
    case startsAt = "starts_at"
    case expiresAt = "expires_at"
    case lastUseDay = "last_use_day"
    case issuedAt = "issued_at"
    case status = "status"
    case fileLicenseId = "file_license_id"
    case generator = "generator"
    case edition = "edition"
    case maxVersion = "max_version"
    case memo = "memo"
    case sourceId = "source_id"
    /// RentalDesk 발급 내역 `format` 열(v1 / legacy)
    case ledgerFormat = "ledger_format"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .managementRef: return "외부 관리 번호"
        case .customerId: return "고객 ID(기존 고객)"
        case .customerName: return "고객명/업체명"
        case .customerContact: return "담당자"
        case .productCode: return "제품 코드"
        case .pcScheme: return "PC 번호 체계"
        case .pcNumber: return "PC 번호"
        case .pcAlias: return "PC 별칭"
        case .startsAt: return "시작 시각"
        case .expiresAt: return "만료 시각(미포함)"
        case .lastUseDay: return "마지막 사용일(서울)"
        case .issuedAt: return "발급 시각"
        case .status: return "처리 상태"
        case .fileLicenseId: return "라이선스 ID(파일 안)"
        case .generator: return "생성 방식"
        case .edition: return "에디션"
        case .maxVersion: return "사용 가능 최고 버전"
        case .memo: return "메모"
        case .sourceId: return "원본 식별자"
        case .ledgerFormat: return "RentalDesk 형식(format)"
        }
    }
}

public enum ImportPreset: String, CaseIterable, Identifiable {
    /// 이 프로그램의 CSV 양식
    case standard
    /// RentalDesk 발급 도구의 issued_licenses.csv
    case rentalDeskLedger

    public var id: String { rawValue }
    public var displayName: String { self == .standard ? "기본 양식" : "RentalDesk 발급 내역(issued_licenses.csv)" }
}

public struct ImportMapping: Equatable {
    public var preset: ImportPreset
    public var columns: [ImportField: Int]
    /// 모든 행에 쓸 제품(제품 코드 열이 없을 때)
    public var fixedProductId: Int64?
    /// 파일 안에서 이름이 같은 신규 고객은 한 고객으로 만든다(기존 고객과는 병합하지 않음)
    public var mergeSameNameInFile: Bool
    /// 파일 안에서 같은 제품·PC 기간이 겹치면 앞 기록을 '대체됨'으로 가져온다(재발급 이력)
    public var supersedeOverlapsInFile: Bool
    public var sourceName: String

    public init(preset: ImportPreset, columns: [ImportField: Int], fixedProductId: Int64? = nil,
                mergeSameNameInFile: Bool = true, supersedeOverlapsInFile: Bool = false, sourceName: String = "") {
        self.preset = preset
        self.columns = columns
        self.fixedProductId = fixedProductId
        self.mergeSameNameInFile = mergeSameNameInFile
        self.supersedeOverlapsInFile = supersedeOverlapsInFile
        self.sourceName = sourceName
    }
}

/// 미리보기 한 줄
public struct ImportPlanRow: Identifiable, Equatable {
    /// CSV 파일의 줄 번호(머리글 = 1)
    public var line: Int
    public var errors: [String] = []
    public var warnings: [String] = []
    public var skip = false
    public var customerText = ""
    public var productText = ""
    public var pcText = ""
    public var periodText = ""
    public var statusText = ""
    public var id: Int { line }

    // 저장용 값
    var customerId: Int64?
    var newCustomerKey: String?
    var newCustomerName = ""
    var newCustomerContact = ""
    var productId: Int64 = 0
    var scheme: PcScheme = .manual
    var pcRaw = ""
    var pcNormalized = ""
    var pcAlias = ""
    var existingPcId: Int64?
    var startsAt = Date(timeIntervalSince1970: 0)
    var expiresAt: Date?
    var issuedAt = Date(timeIntervalSince1970: 0)
    var status: ProcessingStatus = .issued
    var generatorId = GeneratorID.manual
    var fileLicenseId: String?
    var importKey = ""
    var externalRef: String?
    var memo = ""
    var conditions: [String: String] = [:]
    /// 파일 안에서 대체할 앞 행
    var supersedesLine: Int?
}

public struct ImportPlan: Equatable {
    public var rows: [ImportPlanRow]
    public var newCustomerNames: [String]
    public var hasErrors: Bool { rows.contains { !$0.errors.isEmpty } }
    public var importCount: Int { rows.filter { $0.errors.isEmpty && !$0.skip }.count }
    public var skipCount: Int { rows.filter(\.skip).count }
}

public final class ImportExportService {
    let db: AppDatabase
    let licenses: LicenseService
    let now: Clock

    public init(db: AppDatabase, licenses: LicenseService, now: @escaping Clock = Date.init) {
        self.db = db
        self.licenses = licenses
        self.now = now
    }

    // MARK: 양식

    public static let templateHeader = ImportField.allCases.filter { $0 != .ledgerFormat }.map(\.rawValue)

    /// 개인정보 없는 예제가 들어 있는 양식
    public static func templateData() -> Data {
        let h = templateHeader
        func row(_ values: [ImportField: String]) -> [String] { h.map { values[ImportField(rawValue: $0)!] ?? "" } }
        let rows = [
            row([.managementRef: "ORDER-0001", .customerName: "예시상사", .productCode: "RENTALDESK", .pcScheme: "lms-pc-v1",
                 .pcNumber: "7IO36-4GQ6P-GKV25-YX5MD-RQLS4", .pcAlias: "사무실 PC", .startsAt: "2026-01-05",
                 .lastUseDay: "2027-01-05", .issuedAt: "2026-01-05 10:30", .status: "issued", .memo: "예제 행", .sourceId: "example-1"]),
            row([.managementRef: "ORDER-0002", .customerName: "예시스튜디오", .productCode: "REVIEWCUT", .pcScheme: "reviewcut-install-id",
                 .pcNumber: "VRN-7KQ2-M9XA-3PDF", .startsAt: "2026-02-01T01:00:00Z", .status: "issued", .sourceId: "example-2"]),
            row([.managementRef: "ORDER-0003", .customerName: "예시공방", .productCode: "OTHERAPP", .pcScheme: "manual",
                 .pcNumber: "00123-ab", .startsAt: "2026-03-01", .expiresAt: "2026-06-01 00:00", .status: "취소됨",
                 .memo: "앞자리 0 보존 예", .sourceId: "example-3"]),
        ]
        return CSV.write(header: h, rows: rows)
    }

    /// 머리글 이름으로 기본 열 연결
    public static func defaultMapping(for table: CSVTable, preset: ImportPreset, sourceName: String = "") -> ImportMapping {
        var cols: [ImportField: Int] = [:]
        let lower = table.header.map { $0.lowercased() }
        func idx(_ name: String) -> Int? { lower.firstIndex(of: name) }
        switch preset {
        case .standard:
            for f in ImportField.allCases { if let i = idx(f.rawValue) { cols[f] = i } }
        case .rentalDeskLedger:
            let map: [(String, ImportField)] = [
                ("license_id", .fileLicenseId), ("issued_at_utc", .issuedAt), ("customer_label", .customerName),
                ("machine_code", .pcNumber), ("edition", .edition), ("expires_at_utc", .expiresAt), ("note", .memo),
                ("kmong_order", .managementRef), ("updates_through", .maxVersion), ("format", .ledgerFormat),
                ("starts_at_utc", .startsAt),
            ]
            for (name, f) in map { if let i = idx(name) { cols[f] = i } }
        }
        return ImportMapping(preset: preset, columns: cols, mergeSameNameInFile: true,
                             supersedeOverlapsInFile: preset == .rentalDeskLedger, sourceName: sourceName)
    }

    // MARK: 미리보기

    public func plan(_ table: CSVTable, _ mapping: ImportMapping) throws -> ImportPlan {
        try db.read { db in try buildPlan(db, table, mapping) }
    }

    /// 날짜 해석: `YYYY-MM-DDTHH:MM:SSZ`(UTC), `YYYY-MM-DD`(서울 00:00, 날짜만), `YYYY-MM-DD HH:MM[:SS]`(서울)
    static func parseTime(_ s: String) -> (date: Date, dateOnly: Bool)? {
        let v = s.trimmed.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        if let d = LicenseTime.parseUTC(s.trimmed) { return (d, false) }
        if let d = LicenseTime.parseUTCMillis(s.trimmed) { return (LicenseTime.truncated(d), false) }
        if let day = CivilDate(string: v) { return (LicenseTime.seoulMidnight(day), true) }
        let parts = v.split(separator: " ")
        if parts.count == 2, let day = CivilDate(string: String(parts[0])) {
            let hm = parts[1].split(separator: ":").map { Int($0) }
            if (2...3).contains(hm.count), hm.allSatisfy({ $0 != nil }) {
                let h = hm[0]!, m = hm[1]!, sec = hm.count == 3 ? hm[2]! : 0
                if (0..<24).contains(h), (0..<60).contains(m), (0..<60).contains(sec) {
                    return (LicenseTime.seoulDateTime(day, hour: h, minute: m, second: sec), false)
                }
            }
        }
        return nil
    }

    static func parseStatus(_ s: String) -> ProcessingStatus? {
        switch s.trimmed.lowercased() {
        case "", "issued", "발급됨", "발급": return .issued
        case "cancelled", "canceled", "취소됨", "취소": return .cancelled
        case "superseded", "대체됨", "대체": return .superseded
        default: return nil
        }
    }

    func buildPlan(_ db: Database, _ table: CSVTable, _ m: ImportMapping) throws -> ImportPlan {
        let products = try Product.fetchAll(db)
        var rows: [ImportPlanRow] = []
        var newCustomerNames: [String] = []
        var keysInFile: [String: Int] = [:]
        // 파일 안 신규 PC: (체계, 번호) → 고객 키
        var newPcOwner: [String: String] = [:]
        let t = now()

        for (i, r) in table.rows.enumerated() {
            var p = ImportPlanRow(line: i + 2)
            func col(_ f: ImportField) -> String { table.value(r, m.columns[f]).trimmed }

            // 제품
            if let fixed = m.fixedProductId, let prod = products.first(where: { $0.id == fixed }) {
                p.productId = fixed
                p.productText = prod.name
            } else if let code = col(.productCode).nilIfEmpty {
                if let prod = products.first(where: { $0.code == code || $0.v1ProductCode == code }) {
                    p.productId = prod.id!
                    p.productText = prod.name
                } else {
                    p.errors.append("알 수 없는 제품 코드 '\(code)'(제품을 먼저 등록하세요)")
                }
            } else {
                p.errors.append("제품 코드가 없습니다(제품 코드 열을 연결하거나 모든 행의 제품을 고르세요)")
            }

            // 고객: ID가 있으면 기존 고객, 없으면 신규(이름만으로 기존 고객과 병합하지 않음)
            let name = col(.customerName)
            if let idText = col(.customerId).nilIfEmpty {
                if let cid = Int64(idText), let c = try Customer.fetchOne(db, key: cid) {
                    p.customerId = cid
                    p.customerText = "기존 #\(cid) \(c.name)"
                    if !name.isEmpty && name != c.name { p.warnings.append("고객 ID #\(cid)의 이름(\(c.name))과 파일의 이름(\(name))이 다릅니다. ID를 따릅니다.") }
                } else {
                    p.errors.append("고객 ID '\(idText)'가 없습니다")
                }
            } else if name.isEmpty {
                p.errors.append("고객명 또는 고객 ID가 필요합니다")
            } else {
                p.newCustomerName = name
                p.newCustomerContact = col(.customerContact)
                p.newCustomerKey = m.mergeSameNameInFile ? "name:\(name)" : "line:\(p.line)"
                p.customerText = "신규: \(name)"
                if !newCustomerNames.contains(name) || !m.mergeSameNameInFile { newCustomerNames.append(name) }
                let same = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM customer WHERE name = ?", arguments: [name]) ?? 0
                if same > 0 { p.warnings.append("같은 이름의 기존 고객이 \(same)명 있지만 자동 병합하지 않고 새 고객을 만듭니다(기존 고객이면 customer_id 열을 쓰세요)") }
            }

            // PC 번호와 체계
            let number = col(.pcNumber)
            if number.isEmpty {
                p.errors.append("PC 번호가 없습니다")
            } else {
                var scheme: PcScheme
                if m.preset == .rentalDeskLedger {
                    scheme = col(.ledgerFormat).lowercased() == "v1" ? .lmsPcV1 : .rentaldeskMachineV0
                } else if let s = col(.pcScheme).nilIfEmpty {
                    if let sc = PcScheme(rawValue: s) { scheme = sc } else {
                        p.errors.append("알 수 없는 PC 번호 체계 '\(s)'")
                        scheme = .manual
                    }
                } else {
                    scheme = PcScheme.suggest(for: number)
                    p.warnings.append("PC 번호 체계를 모양으로 정했습니다: \(scheme.rawValue)")
                }
                p.scheme = scheme
                p.pcRaw = number
                p.pcNormalized = scheme.normalize(number)
                p.pcAlias = col(.pcAlias)
                p.pcText = scheme.display(normalized: p.pcNormalized)
                if !scheme.isValid(normalized: p.pcNormalized) {
                    p.errors.append("PC 번호 형식 오류: \(scheme.formatHint)")
                } else if let existing = try CustomerPC.fetchOne(db, sql: "SELECT * FROM customer_pc WHERE scheme = ? AND numberNormalized = ?",
                                                                 arguments: [scheme.rawValue, p.pcNormalized]) {
                    let owner = try String.fetchOne(db, sql: "SELECT name FROM customer WHERE id = ?", arguments: [existing.customerId]) ?? "?"
                    if let cid = p.customerId, cid == existing.customerId {
                        p.existingPcId = existing.id
                        p.pcText += " (등록된 PC)"
                    } else {
                        p.errors.append("이미 다른 고객(\(owner) #\(existing.customerId))에 등록된 PC입니다. 그 고객이 맞으면 customer_id 열에 \(existing.customerId)을(를) 넣으세요")
                    }
                } else if let key = p.newCustomerKey ?? p.customerId.map({ "id:\($0)" }) {
                    let pcKey = "\(scheme.rawValue)|\(p.pcNormalized)"
                    if let owner = newPcOwner[pcKey], owner != key {
                        p.errors.append("같은 PC 번호가 파일 안에서 다른 고객에게 쓰였습니다")
                    } else {
                        newPcOwner[pcKey] = key
                        p.pcText += " (신규 PC)"
                    }
                }
            }

            // 기간
            let issuedRaw = col(.issuedAt)
            let startRaw = col(.startsAt)
            var issued: Date?
            var start: Date?
            if !issuedRaw.isEmpty {
                if let v = Self.parseTime(issuedRaw) { issued = v.date } else { p.errors.append("발급 시각 형식 오류 '\(issuedRaw)'") }
            }
            if !startRaw.isEmpty {
                if let v = Self.parseTime(startRaw) { start = v.date } else { p.errors.append("시작 시각 형식 오류 '\(startRaw)'") }
            }
            if start == nil, startRaw.isEmpty { start = issued }
            if issued == nil, issuedRaw.isEmpty { issued = start }
            if start == nil && startRaw.isEmpty && issuedRaw.isEmpty { p.errors.append("시작 시각 또는 발급 시각이 필요합니다") }

            var expires: Date?
            let expRaw = col(.expiresAt)
            let lastRaw = col(.lastUseDay)
            if !expRaw.isEmpty {
                if let v = Self.parseTime(expRaw) {
                    if v.dateOnly {
                        p.errors.append("만료 시각 열에는 시각까지 쓰세요(날짜만 쓰려면 '마지막 사용일' 열 사용): '\(expRaw)'")
                    } else if m.preset == .rentalDeskLedger && col(.ledgerFormat).lowercased() != "v1" {
                        // 이전 형식: 파일은 마지막 사용일 23:59:59 → 관리 기준 다음 날 00:00
                        expires = RentalDeskLegacy.managementExpiry(fromFile: v.date)
                        p.conditions["expires_at_utc(파일)"] = expRaw
                    } else {
                        expires = v.date
                    }
                } else { p.errors.append("만료 시각 형식 오류 '\(expRaw)'") }
            }
            if !lastRaw.isEmpty {
                if let day = CivilDate(string: lastRaw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")) {
                    let e = LicenseTime.endExclusive(lastDay: day)
                    if let x = expires, x != e { p.errors.append("만료 시각과 마지막 사용일이 서로 다릅니다") }
                    expires = e
                } else { p.errors.append("마지막 사용일 형식 오류 '\(lastRaw)'(YYYY-MM-DD)") }
            }
            if let s = start, let e = expires, e <= s { p.errors.append("만료가 시작보다 늦어야 합니다") }
            p.startsAt = start.map(LicenseTime.truncated) ?? t
            p.issuedAt = issued.map(LicenseTime.truncated) ?? p.startsAt
            p.expiresAt = expires.map(LicenseTime.truncated)
            p.periodText = "\(LicenseTime.seoulDisplay(p.startsAt)) ~ " + (p.expiresAt.map { "\(LicenseTime.lastUseDay(expiresAt: $0)) 까지(만료 \(LicenseTime.seoulDisplay($0)))" } ?? "영구")

            // 상태·생성 방식
            if let s = Self.parseStatus(col(.status)) { p.status = s } else { p.errors.append("알 수 없는 처리 상태 '\(col(.status))'(issued/cancelled/superseded)") }
            p.statusText = p.status.displayName
            if let g = col(.generator).nilIfEmpty {
                if let gid = GeneratorID(rawValue: g) { p.generatorId = gid } else { p.errors.append("알 수 없는 생성 방식 '\(g)'") }
            } else {
                p.generatorId = GeneratorRegistry.generator(forScheme: p.scheme)?.id ?? .manual
            }
            if let ed = col(.edition).nilIfEmpty { p.conditions["edition"] = ed }
            if let mv = col(.maxVersion).nilIfEmpty { p.conditions["max_version"] = mv }
            for extra in ["package", "app_version"] {
                if let i = table.header.firstIndex(of: extra), let v = table.value(r, i).trimmed.nilIfEmpty { p.conditions[extra] = v }
            }
            p.memo = col(.memo)
            p.externalRef = col(.managementRef).nilIfEmpty

            // 중복 판정 키: 라이선스 ID > 원본 식별자 > 외부 관리 번호 > 행 내용
            if let lid = col(.fileLicenseId).nilIfEmpty {
                p.fileLicenseId = lid
                p.importKey = "license-id:\(lid)"
            } else if let src = col(.sourceId).nilIfEmpty {
                p.importKey = "source:\(src)"
            } else if let ref = p.externalRef {
                p.importKey = "ref:\(p.productId):\(ref)"
            } else {
                let basis = [String(p.productId), p.scheme.rawValue, p.pcNormalized, DBTime.string(p.startsAt),
                             p.expiresAt.map(DBTime.string) ?? "-", name, col(.customerId)].joined(separator: "|")
                p.importKey = "row:" + TextRules.hex(Data(SHA256.hash(data: Data(basis.utf8)))).prefix(32)
            }
            if let first = keysInFile[p.importKey] {
                p.errors.append("파일 안에서 \(first)번째 줄과 중복입니다")
            } else {
                keysInFile[p.importKey] = p.line
            }
            if p.errors.isEmpty {
                if let no = try String.fetchOne(db, sql: "SELECT managementNo FROM license WHERE importKey = ?", arguments: [p.importKey]) {
                    p.skip = true
                    p.warnings.append("이미 가져온 기록이라 건너뜁니다(관리 번호 \(no))")
                } else if let src = col(.sourceId).nilIfEmpty, src.hasPrefix("lms:"),
                          let no = try String.fetchOne(db, sql: "SELECT managementNo FROM license WHERE managementNo = ?", arguments: [String(src.dropFirst(4))]) {
                    p.skip = true
                    p.warnings.append("이 프로그램에서 내보낸 기록으로, 이미 있어 건너뜁니다(관리 번호 \(no))")
                } else if let lid = p.fileLicenseId,
                          let no = try String.fetchOne(db, sql: "SELECT managementNo FROM license WHERE fileLicenseId = ?", arguments: [lid]) {
                    p.skip = true
                    p.warnings.append("같은 라이선스 ID가 이미 등록되어 있어 건너뜁니다(관리 번호 \(no))")
                }
            }
            rows.append(p)
        }

        try checkOverlaps(db, &rows, m)
        return ImportPlan(rows: rows, newCustomerNames: newCustomerNames)
    }

    /// 기간 중복: 기존 DB의 발급됨 라이선스와 겹치면 오류. 파일 안에서 겹치면 옵션에 따라 앞 기록을 대체됨 처리하거나 오류.
    private func checkOverlaps(_ db: Database, _ rows: inout [ImportPlanRow], _ m: ImportMapping) throws {
        let order = rows.indices.filter { rows[$0].errors.isEmpty && !rows[$0].skip && rows[$0].status == .issued }
            .sorted { (rows[$0].startsAt, rows[$0].line) < (rows[$1].startsAt, rows[$1].line) }
        var active: [String: [Int]] = [:] // 제품·PC → 아직 발급됨으로 남는 행 인덱스
        for idx in order {
            let r = rows[idx]
            if let pcId = r.existingPcId {
                let nos = try LicenseService.overlaps(db, productId: r.productId, pcId: pcId, start: r.startsAt, end: r.expiresAt, excluding: [])
                if !nos.isEmpty { rows[idx].errors.append("기존 발급됨 라이선스와 기간이 겹칩니다: \(nos.joined(separator: ", "))") }
            }
            let key = "\(r.productId)|\(r.scheme.rawValue)|\(r.pcNormalized)"
            var keep: [Int] = []
            for j in active[key] ?? [] {
                let o = rows[j]
                let overlap = (o.expiresAt.map { $0 > r.startsAt } ?? true) && (r.expiresAt.map { o.startsAt < $0 } ?? true)
                if !overlap { keep.append(j); continue }
                if m.supersedeOverlapsInFile && rows[idx].supersedesLine == nil {
                    rows[idx].supersedesLine = o.line
                    rows[idx].warnings.append("\(o.line)번째 줄 기록을 '대체됨'으로 하고 이 기록과 연결합니다(재발급 이력)")
                    rows[j].warnings.append("\(r.line)번째 줄 기록으로 대체됨 처리됩니다")
                    rows[j].statusText = "대체됨(가져오기)"
                } else {
                    rows[idx].errors.append("\(o.line)번째 줄과 같은 제품·PC 기간이 겹칩니다")
                    keep.append(j)
                }
            }
            if rows[idx].errors.isEmpty { keep.append(idx) }
            active[key] = keep
        }
    }

    // MARK: 저장(전체 성공 또는 전체 취소)

    /// 검증 오류가 하나라도 있으면 아무것도 저장하지 않는다. 저장한 라이선스 수를 돌려준다.
    @discardableResult
    public func commit(_ table: CSVTable, _ mapping: ImportMapping) throws -> Int {
        do {
            return try db.write { db in
                let plan = try buildPlan(db, table, mapping)
                if plan.hasErrors {
                    throw StoreError.invalid(field: nil, message: "검증 오류가 있어 저장하지 않았습니다. 미리보기에서 오류 행을 확인하세요.")
                }
                let t = now()
                let ts = DBTime.string(t)
                var customerIds: [String: Int64] = [:]
                var pcIds: [String: Int64] = [:]
                var licenseIdByLine: [Int: Int64] = [:]
                var count = 0
                let ordered = plan.rows.filter { !$0.skip }.sorted { ($0.startsAt, $0.line) < ($1.startsAt, $1.line) }
                for r in ordered {
                    // 고객
                    let cid: Int64
                    if let id = r.customerId { cid = id } else if let key = r.newCustomerKey, let id = customerIds[key] { cid = id } else {
                        var c = Customer(name: r.newCustomerName, contactPerson: r.newCustomerContact, createdAt: ts, updatedAt: ts)
                        try c.insert(db)
                        try Audit.log(db, entity: "customer", id: c.id!, action: "import", summary: "가져오기로 고객 생성: \(c.name)", now: t)
                        cid = c.id!
                        if let key = r.newCustomerKey { customerIds[key] = cid }
                    }
                    // PC
                    let pcKey = "\(r.scheme.rawValue)|\(r.pcNormalized)"
                    let pid: Int64
                    if let id = r.existingPcId { pid = id } else if let id = pcIds[pcKey] { pid = id } else if
                        let id = try Int64.fetchOne(db, sql: "SELECT id FROM customer_pc WHERE scheme = ? AND numberNormalized = ? AND customerId = ?",
                                                    arguments: [r.scheme.rawValue, r.pcNormalized, cid]) {
                        pid = id
                    } else {
                        var pc = CustomerPC(customerId: cid, scheme: r.scheme, numberRaw: r.pcRaw, numberNormalized: r.pcNormalized,
                                            alias: r.pcAlias, createdAt: ts, updatedAt: ts)
                        try pc.insert(db)
                        try Audit.log(db, entity: "customer_pc", id: pc.id!, action: "import",
                                      summary: "가져오기로 PC 등록: \(r.scheme.rawValue) \(Mask.pc(r.pcNormalized))", now: t)
                        pid = pc.id!
                    }
                    pcIds[pcKey] = pid

                    var conditions = r.conditions
                    conditions["product_name"] = r.productText
                    conditions["pc_scheme"] = r.scheme.rawValue
                    conditions["pc_number"] = r.pcNormalized
                    conditions["import_source"] = mapping.sourceName
                    conditions["import_line"] = String(r.line)
                    conditions["note"] = "가져온 기록입니다. 라이선스 파일이 없어 고객 프로그램과의 호환성은 확인되지 않았습니다."
                    var predecessor: Predecessor?
                    if let prevLine = r.supersedesLine, let prevId = licenseIdByLine[prevLine] {
                        predecessor = Predecessor(licenseId: prevId, kind: .renewal, reason: "가져오기: 같은 PC 재발급(\(prevLine)번째 줄)", supersede: true)
                    }
                    let draft = LicenseService.LicenseDraft(
                        customerId: cid, productId: r.productId, pcId: pid, issueMethod: .import, verification: .unverified,
                        verificationDetail: "가져오기(파일 없음)", generatorId: r.generatorId.rawValue, generatorVersion: "",
                        keyId: nil, fileLicenseId: r.fileLicenseId, startsAt: r.startsAt, expiresAt: r.expiresAt, issuedAt: r.issuedAt,
                        licenseFile: nil, licenseFileName: nil, signedPayload: nil, conditions: conditions, memo: r.memo,
                        externalRef: r.externalRef, importSource: mapping.sourceName, importKey: r.importKey, requestToken: nil,
                        predecessor: predecessor)
                    // 취소·대체 상태 행은 중복 검사 대상이 아니므로 먼저 저장 후 상태를 바꾼다
                    let saved: License
                    if r.status == .issued {
                        saved = try licenses.insert(db, draft, auditSummary: "가져오기(\(mapping.sourceName) \(r.line)번째 줄)")
                    } else {
                        saved = try insertHistorical(db, draft, status: r.status, line: r.line, source: mapping.sourceName)
                    }
                    licenseIdByLine[r.line] = saved.id!
                    count += 1
                }
                return count
            }
        } catch { throw StoreError.from(error) }
    }

    /// 이미 취소·대체된 과거 기록: 기간 중복 검사 없이 저장하고 상태를 원본대로 바꾼다.
    private func insertHistorical(_ db: Database, _ d: LicenseService.LicenseDraft, status: ProcessingStatus, line: Int, source: String) throws -> License {
        let t = now()
        let ts = DBTime.string(t)
        let managementNo = try LicenseService.nextManagementNo(db, now: t)
        var license = License(
            id: nil, managementNo: managementNo, customerId: d.customerId, productId: d.productId,
            pcId: d.pcId, status: .issued, issueMethod: .import, verification: .unverified, verificationDetail: d.verificationDetail,
            generatorId: d.generatorId, generatorVersion: d.generatorVersion, keyId: nil, fileLicenseId: d.fileLicenseId,
            startsAt: DBTime.string(d.startsAt), expiresAt: d.expiresAt.map(DBTime.string), issuedAt: DBTime.string(d.issuedAt),
            licenseFile: nil, licenseFileName: nil, signedPayload: nil, conditionsJSON: SnapshotJSON.encode(d.conditions),
            memo: d.memo, externalRef: d.externalRef, importSource: d.importSource, importKey: d.importKey, requestToken: nil,
            statusReason: nil, statusChangedAt: nil, createdAt: ts, updatedAt: ts)
        try license.insert(db)
        try db.execute(sql: "UPDATE license SET status = ?, statusReason = ?, statusChangedAt = ? WHERE id = ?",
                       arguments: [status.rawValue, "가져오기 원본 상태", ts, license.id])
        license.status = status
        try Audit.log(db, entity: "license", id: license.id!, action: "import",
                      summary: "\(license.managementNo) 가져오기(\(source) \(line)번째 줄, 원본 상태 \(status.displayName))", now: t)
        return license
    }

    // MARK: 내보내기

    public static let exportHeader = ["management_no"] + templateHeader + ["pc_display", "effective_status", "verification", "issue_method"]

    /// 현재 검색 결과 내보내기. PC 번호 앞자리 0·한글 보존, 수식 위험 셀은 작은따옴표로 보호.
    public func exportCSV(_ rows: [LicenseRow]) -> Data {
        let t = now()
        let out: [[String]] = rows.map { row in
            let l = row.license
            let values: [ImportField: String] = [
                .managementRef: l.externalRef ?? "",
                .customerId: String(l.customerId),
                .customerName: row.customerName,
                .productCode: row.productCode,
                .pcScheme: row.pcScheme.rawValue,
                .pcNumber: row.pcNumber,
                .pcAlias: row.pcAlias,
                .startsAt: l.startsAt,
                .expiresAt: l.expiresAt ?? "",
                .lastUseDay: l.expiresDate.map { LicenseTime.lastUseDay(expiresAt: $0).description } ?? "",
                .issuedAt: l.issuedAt,
                .status: l.status.rawValue,
                .fileLicenseId: l.fileLicenseId ?? "",
                .generator: l.generatorId,
                .edition: l.conditions["edition"] ?? "",
                .maxVersion: l.conditions["max_version"] ?? l.conditions["updates_through"] ?? "",
                .memo: l.memo,
                .sourceId: "lms:\(l.managementNo)",
            ]
            return [l.managementNo] + Self.templateHeader.map { values[ImportField(rawValue: $0)!] ?? "" }
                + [row.pcDisplay, row.effective(now: t).displayName, l.verification.displayName, l.issueMethod.displayName]
        }
        return CSV.write(header: Self.exportHeader, rows: out)
    }
}
