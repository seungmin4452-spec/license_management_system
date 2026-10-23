import Foundation
import GRDB
import LicenseCore

public struct CustomerInput: Equatable {
    public var name: String
    public var contactPerson: String
    public var phone: String
    public var email: String
    public var memo: String

    public init(name: String = "", contactPerson: String = "", phone: String = "", email: String = "", memo: String = "") {
        self.name = name
        self.contactPerson = contactPerson
        self.phone = phone
        self.email = email
        self.memo = memo
    }

    public init(_ c: Customer) {
        self.init(name: c.name, contactPerson: c.contactPerson, phone: c.phone, email: c.email, memo: c.memo)
    }
}

public struct PCInput: Equatable {
    public var scheme: PcScheme
    public var number: String
    public var alias: String
    public var memo: String

    public init(scheme: PcScheme = .lmsPcV1, number: String = "", alias: String = "", memo: String = "") {
        self.scheme = scheme
        self.number = number
        self.alias = alias
        self.memo = memo
    }
}

/// PC 번호 확인 결과(등록 전 미리보기)
public struct PCCheck: Equatable {
    public var scheme: PcScheme
    public var raw: String
    public var normalized: String
    public var display: String
    public var isValid: Bool
    public var message: String?
    /// 이미 등록된 PC
    public var existing: CustomerPC?
    public var existingOwnerName: String?
}

public final class CustomerService {
    let db: AppDatabase
    let now: Clock

    public init(db: AppDatabase, now: @escaping Clock = Date.init) {
        self.db = db
        self.now = now
    }

    // MARK: 고객

    public func list(query: String = "", includeArchived: Bool = false) throws -> [Customer] {
        try db.read { db in
            var sql = "SELECT * FROM customer WHERE 1 = 1"
            var args: [DatabaseValueConvertible?] = []
            if !includeArchived { sql += " AND isArchived = 0" }
            if let q = query.nilIfEmpty {
                sql += " AND (name LIKE ? ESCAPE '\\' OR contactPerson LIKE ? ESCAPE '\\' OR memo LIKE ? ESCAPE '\\')"
                let like = SQLText.like(q)
                args += [like, like, like]
            }
            sql += " ORDER BY name COLLATE NOCASE, id"
            return try Customer.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    public func get(_ id: Int64) throws -> Customer {
        guard let c = try db.read({ db in try Customer.fetchOne(db, key: id) }) else { throw StoreError.notFound("고객") }
        return c
    }

    func validate(_ input: CustomerInput) throws -> CustomerInput {
        var x = input
        x.name = x.name.trimmed
        x.contactPerson = x.contactPerson.trimmed
        x.phone = x.phone.trimmed
        x.email = x.email.trimmed
        if x.name.isEmpty { throw StoreError.invalid(field: "name", message: "고객명 또는 업체명을 입력하세요.") }
        if !x.email.isEmpty && (!x.email.contains("@") || x.email.contains(" ")) {
            throw StoreError.invalid(field: "email", message: "이메일 형식이 올바르지 않습니다(선택 입력).")
        }
        return x
    }

    /// 이름이 같아도 다른 고객으로 등록한다(내부 ID로 구분).
    @discardableResult
    public func create(_ input: CustomerInput) throws -> Customer {
        let x = try validate(input)
        let ts = DBTime.string(now())
        return try db.write { db in
            var c = Customer(name: x.name, contactPerson: x.contactPerson, phone: x.phone, email: x.email, memo: x.memo,
                             createdAt: ts, updatedAt: ts)
            try c.insert(db)
            try Audit.log(db, entity: "customer", id: c.id!, action: "create", summary: "고객 등록: \(c.name)", now: now())
            return c
        }
    }

    @discardableResult
    public func update(_ id: Int64, _ input: CustomerInput) throws -> Customer {
        let x = try validate(input)
        return try db.write { db in
            guard var c = try Customer.fetchOne(db, key: id) else { throw StoreError.notFound("고객") }
            let before = c.name
            c.name = x.name
            c.contactPerson = x.contactPerson
            c.phone = x.phone
            c.email = x.email
            c.memo = x.memo
            c.updatedAt = DBTime.string(now())
            try c.update(db)
            try Audit.log(db, entity: "customer", id: id, action: "update",
                          summary: before == c.name ? "고객 정보 수정" : "고객명 변경: \(before) → \(c.name)", now: now())
            return c
        }
    }

    public func setArchived(_ id: Int64, _ archived: Bool) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE customer SET isArchived = ?, updatedAt = ? WHERE id = ?", arguments: [archived, DBTime.string(now()), id])
            try Audit.log(db, entity: "customer", id: id, action: archived ? "archive" : "unarchive",
                          summary: archived ? "고객 보관" : "고객 보관 해제", now: now())
        }
    }

    /// 라이선스 이력이 없는 고객만 삭제(PC 기록도 함께 삭제). 이력이 있으면 보관 처리한다.
    public func delete(_ id: Int64) throws {
        do {
            try db.write { db in
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM license WHERE customerId = ?", arguments: [id]) ?? 0
                guard count == 0 else { throw StoreError.conflict("라이선스 이력이 있는 고객은 삭제할 수 없습니다. 보관 처리하세요.") }
                try db.execute(sql: "DELETE FROM pc_link WHERE pcAId IN (SELECT id FROM customer_pc WHERE customerId = ?) OR pcBId IN (SELECT id FROM customer_pc WHERE customerId = ?)", arguments: [id, id])
                try db.execute(sql: "DELETE FROM customer_pc WHERE customerId = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM customer WHERE id = ?", arguments: [id])
                try Audit.log(db, entity: "customer", id: id, action: "delete", summary: "고객 삭제(이력 없음)", now: now())
            }
        } catch { throw StoreError.from(error) }
    }

    // MARK: PC

    public func pcs(customerId: Int64) throws -> [CustomerPC] {
        try db.read { db in
            try CustomerPC.fetchAll(db, sql: "SELECT * FROM customer_pc WHERE customerId = ? ORDER BY id", arguments: [customerId])
        }
    }

    public func pc(_ id: Int64) throws -> CustomerPC {
        guard let p = try db.read({ db in try CustomerPC.fetchOne(db, key: id) }) else { throw StoreError.notFound("PC") }
        return p
    }

    /// 입력한 PC 번호를 체계 규칙으로 정리하고 중복을 확인한다.
    public func check(scheme: PcScheme, number: String) throws -> PCCheck {
        let raw = number.trimmed
        let normalized = scheme.normalize(raw)
        let valid = scheme.isValid(normalized: normalized)
        var result = PCCheck(scheme: scheme, raw: raw, normalized: normalized, display: scheme.display(normalized: normalized),
                             isValid: valid, message: valid ? nil : scheme.formatHint)
        if valid {
            try db.read { db in
                if let existing = try CustomerPC.fetchOne(db, sql: "SELECT * FROM customer_pc WHERE scheme = ? AND numberNormalized = ?",
                                                          arguments: [scheme.rawValue, normalized]) {
                    result.existing = existing
                    result.existingOwnerName = try String.fetchOne(db, sql: "SELECT name FROM customer WHERE id = ?", arguments: [existing.customerId])
                }
            }
        }
        return result
    }

    /// PC 등록. 같은 체계·정규화 번호가 있으면 막고 소유 고객을 알려준다(임의 재배정 없음).
    @discardableResult
    public func addPC(customerId: Int64, _ input: PCInput) throws -> CustomerPC {
        let c = try check(scheme: input.scheme, number: input.number)
        guard c.isValid else { throw StoreError.invalid(field: "number", message: c.message ?? "PC 번호 형식 오류") }
        if let e = c.existing {
            if e.customerId == customerId {
                throw StoreError.invalid(field: "number", message: "이 고객에게 이미 등록된 PC입니다.")
            }
            throw StoreError.duplicatePC(ownerCustomerId: e.customerId, ownerName: c.existingOwnerName ?? "?")
        }
        let ts = DBTime.string(now())
        do {
            return try db.write { db in
                guard try Customer.fetchOne(db, key: customerId) != nil else { throw StoreError.notFound("고객") }
                var pc = CustomerPC(customerId: customerId, scheme: input.scheme, numberRaw: c.raw, numberNormalized: c.normalized,
                                    alias: input.alias.trimmed, memo: input.memo, createdAt: ts, updatedAt: ts)
                try pc.insert(db)
                try Audit.log(db, entity: "customer_pc", id: pc.id!, action: "create",
                              summary: "PC 등록: \(input.scheme.rawValue) \(Mask.pc(c.normalized)) (고객 #\(customerId))", now: now())
                return pc
            }
        } catch let e as DatabaseError where e.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
            // 동시 등록 경합
            let again = try check(scheme: input.scheme, number: input.number)
            throw StoreError.duplicatePC(ownerCustomerId: again.existing?.customerId ?? 0, ownerName: again.existingOwnerName ?? "?")
        } catch { throw StoreError.from(error) }
    }

    /// 별칭·메모만 수정한다. PC 번호는 발급 이후 바꾸지 않는다(오입력은 새 PC 등록 + 재발급).
    public func updatePC(_ id: Int64, alias: String, memo: String) throws {
        try db.write { db in
            guard var pc = try CustomerPC.fetchOne(db, key: id) else { throw StoreError.notFound("PC") }
            pc.alias = alias.trimmed
            pc.memo = memo
            pc.updatedAt = DBTime.string(now())
            try pc.update(db)
            try Audit.log(db, entity: "customer_pc", id: id, action: "update", summary: "PC 별칭·메모 수정", now: now())
        }
    }

    /// 라이선스가 없는 PC만 삭제(오입력 정리용)
    public func deletePC(_ id: Int64) throws {
        do {
            try db.write { db in
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM license WHERE pcId = ?", arguments: [id]) ?? 0
                guard count == 0 else { throw StoreError.conflict("라이선스가 발급된 PC는 삭제할 수 없습니다.") }
                try db.execute(sql: "DELETE FROM pc_link WHERE pcAId = ? OR pcBId = ?", arguments: [id, id])
                try db.execute(sql: "DELETE FROM customer_pc WHERE id = ?", arguments: [id])
                try Audit.log(db, entity: "customer_pc", id: id, action: "delete", summary: "PC 삭제(라이선스 없음)", now: now())
            }
        } catch { throw StoreError.from(error) }
    }

    // MARK: 같은 PC의 다른 체계 번호 연결

    public func linkPCs(_ a: Int64, _ b: Int64, memo: String = "") throws {
        guard a != b else { throw StoreError.invalid(field: nil, message: "같은 PC 기록끼리는 연결할 수 없습니다.") }
        let (x, y) = a < b ? (a, b) : (b, a)
        do {
            try db.write { db in
                guard let pa = try CustomerPC.fetchOne(db, key: x), let pb = try CustomerPC.fetchOne(db, key: y) else {
                    throw StoreError.notFound("PC")
                }
                guard pa.customerId == pb.customerId else {
                    throw StoreError.invalid(field: nil, message: "같은 고객의 PC끼리만 연결할 수 있습니다.")
                }
                guard pa.scheme != pb.scheme else {
                    throw StoreError.invalid(field: nil, message: "같은 체계의 번호는 서로 다른 PC입니다. 다른 체계 번호끼리 연결하세요.")
                }
                var link = PcLink(pcAId: x, pcBId: y, memo: memo, createdAt: DBTime.string(now()))
                try link.insert(db)
                try Audit.log(db, entity: "customer_pc", id: x, action: "link", summary: "같은 PC로 연결: #\(x) ↔ #\(y)", now: now())
            }
        } catch { throw StoreError.from(error) }
    }

    public func unlinkPCs(_ a: Int64, _ b: Int64) throws {
        let (x, y) = a < b ? (a, b) : (b, a)
        try db.write { db in
            try db.execute(sql: "DELETE FROM pc_link WHERE pcAId = ? AND pcBId = ?", arguments: [x, y])
            try Audit.log(db, entity: "customer_pc", id: x, action: "unlink", summary: "PC 연결 해제: #\(x) ↔ #\(y)", now: now())
        }
    }

    public func linkedPCs(_ pcId: Int64) throws -> [CustomerPC] {
        try db.read { db in
            try CustomerPC.fetchAll(db, sql: """
                SELECT * FROM customer_pc WHERE id IN (
                    SELECT pcBId FROM pc_link WHERE pcAId = ? UNION SELECT pcAId FROM pc_link WHERE pcBId = ?)
                ORDER BY id
                """, arguments: [pcId, pcId])
        }
    }
}

enum SQLText {
    /// LIKE 패턴(%, _, \ 이스케이프). ESCAPE '\' 와 함께 쓴다.
    static func like(_ s: String) -> String {
        var out = "%"
        for ch in s {
            if ch == "%" || ch == "_" || ch == "\\" { out.append("\\") }
            out.append(ch)
        }
        return out + "%"
    }
}
