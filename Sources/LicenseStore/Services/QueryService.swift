import Foundation
import GRDB
import LicenseCore

/// 목록 한 줄(라이선스 + 고객·제품·PC 이름)
public struct LicenseRow: Identifiable, Hashable {
    public var license: License
    public var customerName: String
    public var productName: String
    public var productCode: String
    public var pcScheme: PcScheme
    public var pcNumber: String
    public var pcAlias: String

    public var id: Int64 { license.id ?? 0 }
    public var pcDisplay: String { pcScheme.display(normalized: pcNumber) }
    public func effective(now: Date) -> EffectiveStatus { license.effectiveStatus(now: now) }
}

public enum LicenseSort: String, CaseIterable, Identifiable {
    case newest, expiresSoon, managementNo, customer
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .newest: return "최근 발급 순"
        case .expiresSoon: return "만료 임박 순"
        case .managementNo: return "관리 번호 순"
        case .customer: return "고객명 순"
        }
    }
}

public struct LicenseFilter: Equatable {
    public var query: String = ""
    public var productId: Int64?
    public var status: ProcessingStatus?
    public var effective: EffectiveStatus?
    /// 만료 예정(일). 취소·대체 제외
    public var expiringWithinDays: Int?
    public var customerId: Int64?
    public var pcId: Int64?
    public var sort: LicenseSort = .newest
    public var limit: Int = 2000

    public init(query: String = "", productId: Int64? = nil, status: ProcessingStatus? = nil, effective: EffectiveStatus? = nil,
                expiringWithinDays: Int? = nil, customerId: Int64? = nil, pcId: Int64? = nil, sort: LicenseSort = .newest) {
        self.query = query
        self.productId = productId
        self.status = status
        self.effective = effective
        self.expiringWithinDays = expiringWithinDays
        self.customerId = customerId
        self.pcId = pcId
        self.sort = sort
    }
}

public struct DashboardStats: Equatable {
    public var products: Int
    public var customers: Int
    public var validLicenses: Int
    public var expiring7: Int
    public var expiring30: Int
}

/// 통합 검색 결과
public struct UnifiedSearchResult {
    public var customers: [Customer]
    public var pcs: [(pc: CustomerPC, customerName: String)]
    public var licenses: [LicenseRow]
    public var isEmpty: Bool { customers.isEmpty && pcs.isEmpty && licenses.isEmpty }
}

public struct RelationRow: Identifiable, Hashable {
    public var relation: LicenseRelation
    public var otherManagementNo: String
    public var otherLicenseId: Int64
    public var id: Int64 { relation.id ?? 0 }
}

public struct LicenseDetail {
    public var row: LicenseRow
    public var predecessors: [RelationRow]
    public var successors: [RelationRow]
    public var auditLogs: [AuditLog]
    public var customer: Customer
    public var pc: CustomerPC
    public var product: Product
}

public struct CustomerOverview {
    public var customer: Customer
    public var pcs: [CustomerPC]
    public var licenses: [LicenseRow]
    public var auditLogs: [AuditLog]
}

public final class QueryService {
    let db: AppDatabase
    let now: Clock

    public init(db: AppDatabase, now: @escaping Clock = Date.init) {
        self.db = db
        self.now = now
    }

    static let rowSelect = """
        SELECT license.*, customer.name AS _customerName, product.name AS _productName, product.code AS _productCode,
               customer_pc.scheme AS _pcScheme, customer_pc.numberNormalized AS _pcNumber, customer_pc.alias AS _pcAlias
        FROM license
        JOIN customer ON customer.id = license.customerId
        JOIN product ON product.id = license.productId
        JOIN customer_pc ON customer_pc.id = license.pcId
        """

    static func row(_ r: Row) throws -> LicenseRow {
        LicenseRow(
            license: try License(row: r),
            customerName: r["_customerName"],
            productName: r["_productName"],
            productCode: r["_productCode"],
            pcScheme: PcScheme(rawValue: r["_pcScheme"]) ?? .manual,
            pcNumber: r["_pcNumber"],
            pcAlias: r["_pcAlias"])
    }

    /// PC 번호 검색어 정규화(공백·하이픈 제거, 대문자)
    static func pcQuery(_ q: String) -> String? {
        let n = PcScheme.lmsPcV1.normalize(q)
        return n.isEmpty ? nil : n
    }

    public func licenses(_ f: LicenseFilter) throws -> [LicenseRow] {
        let t = DBTime.string(now())
        var sql = Self.rowSelect + " WHERE 1 = 1"
        var args: [DatabaseValueConvertible?] = []
        if let q = f.query.nilIfEmpty {
            let like = SQLText.like(q)
            var parts = [
                "customer.name LIKE ? ESCAPE '\\'", "customer.contactPerson LIKE ? ESCAPE '\\'",
                "product.name LIKE ? ESCAPE '\\'", "product.code LIKE ? ESCAPE '\\'", "product.v1ProductCode LIKE ? ESCAPE '\\'",
                "customer_pc.numberRaw LIKE ? ESCAPE '\\'", "customer_pc.numberNormalized LIKE ? ESCAPE '\\'", "customer_pc.alias LIKE ? ESCAPE '\\'",
                "license.managementNo LIKE ? ESCAPE '\\'", "license.externalRef LIKE ? ESCAPE '\\'", "license.fileLicenseId LIKE ? ESCAPE '\\'",
            ]
            args += Array(repeating: like, count: parts.count)
            if let pq = Self.pcQuery(q) {
                parts.append("customer_pc.numberNormalized LIKE ? ESCAPE '\\'")
                args.append(SQLText.like(pq))
            }
            sql += " AND (" + parts.joined(separator: " OR ") + ")"
        }
        if let p = f.productId { sql += " AND license.productId = ?"; args.append(p) }
        if let c = f.customerId { sql += " AND license.customerId = ?"; args.append(c) }
        if let pc = f.pcId { sql += " AND license.pcId = ?"; args.append(pc) }
        if let s = f.status { sql += " AND license.status = ?"; args.append(s.rawValue) }
        if let e = f.effective {
            switch e {
            case .notYetValid: sql += " AND license.status = 'issued' AND license.startsAt > ?"; args.append(t)
            case .valid:
                sql += " AND license.status = 'issued' AND license.startsAt <= ? AND (license.expiresAt IS NULL OR license.expiresAt > ?)"
                args += [t, t]
            case .expired: sql += " AND license.status = 'issued' AND license.expiresAt IS NOT NULL AND license.expiresAt <= ?"; args.append(t)
            case .cancelled: sql += " AND license.status = 'cancelled'"
            case .superseded: sql += " AND license.status = 'superseded'"
            }
        }
        if let days = f.expiringWithinDays {
            let until = DBTime.string(now().addingTimeInterval(Double(days) * 86_400))
            sql += " AND license.status = 'issued' AND license.expiresAt IS NOT NULL AND license.expiresAt > ? AND license.expiresAt <= ?"
            args += [t, until]
        }
        switch f.sort {
        case .newest: sql += " ORDER BY license.issuedAt DESC, license.id DESC"
        case .expiresSoon: sql += " ORDER BY license.expiresAt IS NULL, license.expiresAt ASC, license.id"
        case .managementNo: sql += " ORDER BY license.managementNo"
        case .customer: sql += " ORDER BY customer.name COLLATE NOCASE, license.issuedAt DESC"
        }
        sql += " LIMIT \(max(1, f.limit))"
        return try db.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map(Self.row)
        }
    }

    /// 고객명·업체명·제품명/코드·PC 번호·관리 번호 통합 검색
    public func search(_ query: String) throws -> UnifiedSearchResult {
        guard let q = query.nilIfEmpty else { return UnifiedSearchResult(customers: [], pcs: [], licenses: []) }
        let like = SQLText.like(q)
        let pcLike = Self.pcQuery(q).map(SQLText.like) ?? like
        let (customers, pcs) = try db.read { db -> ([Customer], [(pc: CustomerPC, customerName: String)]) in
            let cs = try Customer.fetchAll(db, sql: """
                SELECT * FROM customer WHERE name LIKE ? ESCAPE '\\' OR contactPerson LIKE ? ESCAPE '\\'
                ORDER BY isArchived, name COLLATE NOCASE LIMIT 200
                """, arguments: [like, like])
            let rows = try Row.fetchAll(db, sql: """
                SELECT customer_pc.*, customer.name AS _customerName FROM customer_pc
                JOIN customer ON customer.id = customer_pc.customerId
                WHERE customer_pc.numberRaw LIKE ? ESCAPE '\\' OR customer_pc.numberNormalized LIKE ? ESCAPE '\\'
                   OR customer_pc.numberNormalized LIKE ? ESCAPE '\\' OR customer_pc.alias LIKE ? ESCAPE '\\'
                ORDER BY customer_pc.id LIMIT 200
                """, arguments: [like, like, pcLike, like])
            let ps = try rows.map { (pc: try CustomerPC(row: $0), customerName: $0["_customerName"] as String) }
            return (cs, ps)
        }
        var f = LicenseFilter(query: q)
        f.limit = 500
        return UnifiedSearchResult(customers: customers, pcs: pcs, licenses: try licenses(f))
    }

    public func dashboard() throws -> DashboardStats {
        let t = now()
        let ts = DBTime.string(t)
        let d7 = DBTime.string(t.addingTimeInterval(7 * 86_400))
        let d30 = DBTime.string(t.addingTimeInterval(30 * 86_400))
        return try db.read { db in
            DashboardStats(
                products: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM product WHERE isArchived = 0") ?? 0,
                customers: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM customer WHERE isArchived = 0") ?? 0,
                validLicenses: try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM license WHERE status = 'issued' AND startsAt <= ? AND (expiresAt IS NULL OR expiresAt > ?)
                    """, arguments: [ts, ts]) ?? 0,
                expiring7: try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM license WHERE status = 'issued' AND expiresAt IS NOT NULL AND expiresAt > ? AND expiresAt <= ?
                    """, arguments: [ts, d7]) ?? 0,
                expiring30: try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM license WHERE status = 'issued' AND expiresAt IS NOT NULL AND expiresAt > ? AND expiresAt <= ?
                    """, arguments: [ts, d30]) ?? 0)
        }
    }

    public func customerOverview(_ id: Int64) throws -> CustomerOverview {
        let (c, pcs, logs) = try db.read { db -> (Customer?, [CustomerPC], [AuditLog]) in
            (try Customer.fetchOne(db, key: id),
             try CustomerPC.fetchAll(db, sql: "SELECT * FROM customer_pc WHERE customerId = ? ORDER BY id", arguments: [id]),
             try AuditLog.fetchAll(db, sql: """
                SELECT * FROM audit_log WHERE (entityType = 'customer' AND entityId = ?)
                   OR (entityType = 'customer_pc' AND entityId IN (SELECT id FROM customer_pc WHERE customerId = ?))
                   OR (entityType = 'license' AND entityId IN (SELECT id FROM license WHERE customerId = ?))
                ORDER BY id DESC LIMIT 500
                """, arguments: [id, id, id]))
        }
        guard let customer = c else { throw StoreError.notFound("고객") }
        var f = LicenseFilter(customerId: id)
        f.sort = .newest
        return CustomerOverview(customer: customer, pcs: pcs, licenses: try licenses(f), auditLogs: logs)
    }

    public func licenseDetail(_ id: Int64) throws -> LicenseDetail {
        try db.read { db in
            guard let r = try Row.fetchOne(db, sql: Self.rowSelect + " WHERE license.id = ?", arguments: [id]) else {
                throw StoreError.notFound("라이선스")
            }
            let row = try Self.row(r)
            func relations(_ sql: String) throws -> [RelationRow] {
                try Row.fetchAll(db, sql: sql, arguments: [id]).map { rr in
                    RelationRow(relation: try LicenseRelation(row: rr), otherManagementNo: rr["_otherNo"], otherLicenseId: rr["_otherId"])
                }
            }
            let preds = try relations("""
                SELECT license_relation.*, license.managementNo AS _otherNo, license.id AS _otherId FROM license_relation
                JOIN license ON license.id = license_relation.fromLicenseId WHERE license_relation.toLicenseId = ?
                """)
            let succs = try relations("""
                SELECT license_relation.*, license.managementNo AS _otherNo, license.id AS _otherId FROM license_relation
                JOIN license ON license.id = license_relation.toLicenseId WHERE license_relation.fromLicenseId = ?
                """)
            let logs = try AuditLog.fetchAll(db, sql: "SELECT * FROM audit_log WHERE entityType = 'license' AND entityId = ? ORDER BY id DESC", arguments: [id])
            guard let customer = try Customer.fetchOne(db, key: row.license.customerId),
                  let pc = try CustomerPC.fetchOne(db, key: row.license.pcId),
                  let product = try Product.fetchOne(db, key: row.license.productId) else { throw StoreError.notFound("연결 기록") }
            return LicenseDetail(row: row, predecessors: preds, successors: succs, auditLogs: logs,
                                 customer: customer, pc: pc, product: product)
        }
    }

    public func recentAudit(limit: Int = 200) throws -> [AuditLog] {
        try db.read { db in try AuditLog.fetchAll(db, sql: "SELECT * FROM audit_log ORDER BY id DESC LIMIT ?", arguments: [limit]) }
    }
}
