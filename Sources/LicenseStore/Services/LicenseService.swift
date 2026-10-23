import Foundation
import GRDB
import LicenseCore

/// 이전 라이선스와의 연결(갱신·PC 교체)
public struct Predecessor: Equatable {
    public var licenseId: Int64
    public var kind: RelationKind
    public var reason: String
    /// 기존 라이선스를 같은 트랜잭션에서 '대체됨' 처리할지
    public var supersede: Bool

    public init(licenseId: Int64, kind: RelationKind, reason: String, supersede: Bool) {
        self.licenseId = licenseId
        self.kind = kind
        self.reason = reason
        self.supersede = supersede
    }
}

/// 자동 발급 입력. 순서: 고객 → 제품 → PC → 영구/기간제 → 시작·만료 → 메모
public struct IssueForm: Equatable {
    public var customerId: Int64
    public var productId: Int64
    public var pcId: Int64
    public var generatorId: GeneratorID
    public var startsAt: Date
    /// 관리 기준 만료(미포함). nil = 영구
    public var expiresAt: Date?
    /// 고객 표시명(라이선스 파일에 들어감). 연락처·이메일 금지
    public var licensee: String
    public var edition: String
    /// "" = 버전 제한 없음
    public var maxVersion: String
    public var options: [String: String]
    public var memo: String
    public var externalRef: String
    /// 중복 클릭·중복 요청 방지 토큰(폼마다 하나)
    public var requestToken: String
    public var predecessor: Predecessor?

    public init(customerId: Int64, productId: Int64, pcId: Int64, generatorId: GeneratorID, startsAt: Date, expiresAt: Date?,
                licensee: String = "", edition: String = "standard", maxVersion: String = "", options: [String: String] = [:],
                memo: String = "", externalRef: String = "", requestToken: String = UUID().uuidString, predecessor: Predecessor? = nil) {
        self.customerId = customerId
        self.productId = productId
        self.pcId = pcId
        self.generatorId = generatorId
        self.startsAt = startsAt
        self.expiresAt = expiresAt
        self.licensee = licensee
        self.edition = edition
        self.maxVersion = maxVersion
        self.options = options
        self.memo = memo
        self.externalRef = externalRef
        self.requestToken = requestToken
        self.predecessor = predecessor
    }
}

/// 수동 등록 입력(기존 라이선스 파일 또는 문자열, 또는 파일 없이 기록만)
public struct ManualForm: Equatable {
    public var customerId: Int64
    public var productId: Int64
    public var pcId: Int64
    public var fileBytes: Data?
    public var fileName: String?
    /// 서명 검증을 통과하지 못했거나 파일이 없을 때 쓰는 관리상 기간
    public var startsAt: Date
    public var expiresAt: Date?
    public var issuedAt: Date?
    public var memo: String
    public var externalRef: String
    public var requestToken: String
    public var predecessor: Predecessor?

    public init(customerId: Int64, productId: Int64, pcId: Int64, fileBytes: Data?, fileName: String?, startsAt: Date,
                expiresAt: Date?, issuedAt: Date? = nil, memo: String = "", externalRef: String = "",
                requestToken: String = UUID().uuidString, predecessor: Predecessor? = nil) {
        self.customerId = customerId
        self.productId = productId
        self.pcId = pcId
        self.fileBytes = fileBytes
        self.fileName = fileName
        self.startsAt = startsAt
        self.expiresAt = expiresAt
        self.issuedAt = issuedAt
        self.memo = memo
        self.externalRef = externalRef
        self.requestToken = requestToken
        self.predecessor = predecessor
    }
}

/// 갱신 제안
public struct RenewPlan: Equatable {
    public var suggestedStart: Date
    public var suggestedExpiry: Date?
    /// 기존 라이선스를 대체 처리해야 하는지(미래 시작 불가 생성기, 또는 기존이 영구)
    public var mustSupersede: Bool
    public var explanation: String
}

public final class LicenseService {
    let db: AppDatabase
    let products: ProductService
    let now: Clock
    /// 테스트에서 트랜잭션 중간 실패를 일으키는 지점("after-supersede", "before-insert")
    var failpoint: ((String) throws -> Void)?

    public init(db: AppDatabase, products: ProductService, now: @escaping Clock = Date.init) {
        self.db = db
        self.products = products
        self.now = now
    }

    // MARK: - 조회

    public func get(_ id: Int64) throws -> License {
        guard let l = try db.read({ db in try License.fetchOne(db, key: id) }) else { throw StoreError.notFound("라이선스") }
        return l
    }

    // MARK: - 발급 전 검사

    struct Context {
        var customer: Customer
        var product: Product
        var pc: CustomerPC
        var enabled: Set<GeneratorID>
    }

    func context(customerId: Int64, productId: Int64, pcId: Int64) throws -> Context {
        try db.read { db in
            guard let c = try Customer.fetchOne(db, key: customerId) else { throw StoreError.notFound("고객") }
            guard let p = try Product.fetchOne(db, key: productId) else { throw StoreError.notFound("제품") }
            guard let pc = try CustomerPC.fetchOne(db, key: pcId) else { throw StoreError.notFound("PC") }
            let gens = try ProductGenerator.fetchAll(db, sql: "SELECT * FROM product_generator WHERE productId = ? AND isEnabled = 1", arguments: [productId])
            return Context(customer: c, product: p, pc: pc, enabled: Set(gens.compactMap(\.generator)))
        }
    }

    func makeRequest(_ form: IssueForm, ctx: Context, issuedAt: Date) -> LicenseRequest {
        LicenseRequest(
            productCode: ctx.product.v1ProductCode ?? "",
            pcScheme: ctx.pc.scheme, pcRaw: ctx.pc.numberRaw, pcNormalized: ctx.pc.numberNormalized,
            issuedAt: issuedAt, startsAt: form.startsAt, expiresAt: form.expiresAt,
            licensee: form.licensee.nilIfEmpty, edition: form.edition.trimmed,
            maxVersion: form.maxVersion.nilIfEmpty, options: form.options)
    }

    /// 입력 단계 검사(지원하지 않는 조건·기간 중복·연결 규칙). 빈 배열이면 발급 가능.
    public func check(_ form: IssueForm) -> [ValidationIssue] {
        let ctx: Context
        do { ctx = try context(customerId: form.customerId, productId: form.productId, pcId: form.pcId) } catch {
            return [.init(.general, error.localizedDescription)]
        }
        var issues = contextIssues(ctx, generatorId: form.generatorId)
        guard let gen = GeneratorRegistry.generator(for: form.generatorId) else {
            return issues + [.init(.general, "자동 발급할 수 없는 생성 방식입니다(수동 등록을 사용하세요).")]
        }
        let t = now()
        let request = makeRequest(form, ctx: ctx, issuedAt: t)
        issues += gen.validate(request, now: t)
        // 관리 기준 시작: 미래 시작 불가 생성기는 발급 시각
        let start = gen.capabilities.futureStart ? request.startsAt : t
        if let p = form.predecessor { issues += predecessorIssues(p, ctx: ctx, newPcId: form.pcId) }
        if issues.isEmpty {
            let excluded = (form.predecessor?.supersede ?? false) ? [form.predecessor!.licenseId] : []
            if let nos = try? db.read({ db in
                try Self.overlaps(db, productId: form.productId, pcId: form.pcId, start: start, end: form.expiresAt, excluding: excluded)
            }), !nos.isEmpty {
                issues.append(.init(.period, StoreError.overlap(nos).errorDescription!))
            }
        }
        return issues
    }

    func contextIssues(_ ctx: Context, generatorId: GeneratorID) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if ctx.pc.customerId != ctx.customer.id {
            issues.append(.init(.pc, "선택한 PC가 이 고객의 PC가 아닙니다."))
        }
        if ctx.product.isArchived { issues.append(.init(.general, "보관된 제품에는 발급할 수 없습니다.")) }
        if !ctx.enabled.contains(generatorId) {
            issues.append(.init(.general, "이 제품에 '\(generatorId.displayName)' 생성 방식이 설정되어 있지 않습니다."))
        }
        if let scheme = generatorId.scheme, scheme != ctx.pc.scheme {
            issues.append(.init(.pc, "\(generatorId.displayName)은(는) \(scheme.displayName) PC 번호에만 발급합니다. 선택한 PC는 \(ctx.pc.scheme.displayName)입니다."))
        }
        return issues
    }

    func predecessorIssues(_ p: Predecessor, ctx: Context, newPcId: Int64) -> [ValidationIssue] {
        guard let old = try? get(p.licenseId) else { return [.init(.general, "이전 라이선스를 찾을 수 없습니다.")] }
        var issues: [ValidationIssue] = []
        if old.status != .issued { issues.append(.init(.general, "이전 라이선스가 이미 \(old.status.displayName) 상태입니다.")) }
        if old.productId != ctx.product.id { issues.append(.init(.general, "이전 라이선스와 제품이 다릅니다.")) }
        if old.customerId != ctx.customer.id { issues.append(.init(.general, "이전 라이선스와 고객이 다릅니다.")) }
        switch p.kind {
        case .replacement:
            if old.pcId == newPcId { issues.append(.init(.pc, "PC 교체는 다른 PC를 골라야 합니다.")) }
            if p.reason.trimmed.isEmpty { issues.append(.init(.general, "PC 교체 사유를 입력하세요.")) }
            if !p.supersede { issues.append(.init(.general, "PC 교체는 기존 라이선스를 대체 처리합니다.")) }
        case .renewal:
            if old.pcId != newPcId { issues.append(.init(.pc, "갱신은 같은 PC에 발급합니다. PC가 바뀌었으면 PC 교체를 사용하세요.")) }
        }
        return issues
    }

    // MARK: - 자동 발급

    /// 내장 생성기로 서명된 라이선스를 만들고, 공개키로 다시 검증한 뒤에만 저장한다(같은 트랜잭션: 대체 처리·저장·감사 기록).
    /// 같은 requestToken으로 다시 부르면 새로 만들지 않고 이미 저장된 라이선스를 돌려준다.
    @discardableResult
    public func issue(_ form: IssueForm) throws -> License {
        if let existing = try findByToken(form.requestToken) { return existing }
        let issues = check(form)
        guard issues.isEmpty else { throw StoreError.generation(issues) }
        let ctx = try context(customerId: form.customerId, productId: form.productId, pcId: form.pcId)
        guard let gen = GeneratorRegistry.generator(for: form.generatorId) else { throw StoreError.generation([]) }
        let (material, keyRow) = try products.signingMaterial(productId: form.productId)
        let t = now()
        let request = makeRequest(form, ctx: ctx, issuedAt: t)
        let generated: GeneratedLicense
        do { generated = try gen.generate(request, signing: material, now: t) } catch let e as GenerationError {
            throw StoreError.generation(e.issues)
        }

        // 발급 직후 검증: 등록된 공개키로 다시 검사하고 내용이 입력과 같은지 확인
        guard let inspected = gen.inspect(fileBytes: generated.fileBytes, publicKeys: [keyRow.publicKeyRef]) else {
            throw StoreError.selfVerificationFailed("형식 판별 실패")
        }
        guard inspected.check == .verified else { throw StoreError.selfVerificationFailed(inspected.check.displayText) }
        guard inspected.licenseId == generated.licenseIdInFile, inspected.pcNumber == ctx.pc.numberNormalized else {
            throw StoreError.selfVerificationFailed("파일 내용이 입력과 다릅니다")
        }
        if form.generatorId == .lmsLicenseV1, inspected.productCode != ctx.product.v1ProductCode {
            throw StoreError.selfVerificationFailed("제품 코드 불일치")
        }

        var conditions = generated.fileConditions
        conditions["product_name"] = ctx.product.name
        conditions["product_code_at_issue"] = ctx.product.code
        conditions["pc_scheme"] = ctx.pc.scheme.rawValue
        conditions["pc_number"] = ctx.pc.numberNormalized
        conditions["generator"] = "\(generated.generatorID.rawValue) \(generated.generatorVersion)"
        conditions["management_period"] = "[\(DBTime.string(generated.startsAt)), \(generated.expiresAt.map(DBTime.string) ?? "영구"))"

        let draft = LicenseDraft(
            customerId: form.customerId, productId: form.productId, pcId: form.pcId, issueMethod: .auto,
            verification: .verified, verificationDetail: "발급 직후 공개키(\(keyRow.keyId)) 검증 통과",
            generatorId: generated.generatorID.rawValue, generatorVersion: generated.generatorVersion,
            keyId: generated.keyId ?? keyRow.keyId, fileLicenseId: generated.licenseIdInFile,
            startsAt: generated.startsAt, expiresAt: generated.expiresAt, issuedAt: LicenseTime.truncated(t),
            licenseFile: generated.fileBytes, licenseFileName: generated.fileName,
            signedPayload: generated.signedMessageText, conditions: conditions,
            memo: form.memo, externalRef: form.externalRef.nilIfEmpty, importSource: nil, importKey: nil,
            requestToken: form.requestToken, predecessor: form.predecessor)
        return try save(draft, auditSummary: "자동 발급: \(ctx.product.name) / \(ctx.customer.name) / \(ctx.pc.scheme.rawValue) \(Mask.pc(ctx.pc.numberNormalized))")
    }

    func findByToken(_ token: String) throws -> License? {
        try db.read { db in try License.fetchOne(db, sql: "SELECT * FROM license WHERE requestToken = ?", arguments: [token]) }
    }

    // MARK: - 수동 등록

    /// 파일 내용 미리보기(서명 검증 + 내용 자동 채움). 형식을 모르면 nil.
    public func inspect(fileBytes: Data, productId: Int64?) -> InspectedLicense? {
        let keys = (try? products.publicKeys(productId: productId)) ?? []
        return GeneratorRegistry.inspectAny(fileBytes: fileBytes, publicKeys: keys)
    }

    /// 수동 등록. 공통·이전 형식 파일이면 서명을 검증하고 내용(PC 번호, 기간, 라이선스 ID)을 파일에서 가져온다.
    /// 검증에 실패하거나 형식을 모르면 '호환성 미검증'으로 등록하고 입력한 관리상 기간을 쓴다.
    @discardableResult
    public func registerManual(_ form: ManualForm) throws -> License {
        if let existing = try findByToken(form.requestToken) { return existing }
        let ctx = try context(customerId: form.customerId, productId: form.productId, pcId: form.pcId)
        if ctx.pc.customerId != ctx.customer.id { throw StoreError.invalid(field: "pc", message: "선택한 PC가 이 고객의 PC가 아닙니다.") }
        let t = now()

        var verification = Verification.unverified
        var detail = "파일 없음(기록만 등록)"
        var generatorId = GeneratorID.manual.rawValue
        var generatorVersion = ""
        var keyId: String?
        var fileLicenseId: String?
        var startsAt = form.startsAt
        var expiresAt = form.expiresAt
        var issuedAt = form.issuedAt ?? t
        var signed: String?
        var conditions: [String: String] = [:]

        if let bytes = form.fileBytes {
            guard bytes.count <= 64 * 1024 else { throw StoreError.invalid(field: "file", message: "라이선스 파일이 너무 큽니다(64KB 초과).") }
            if let ins = inspect(fileBytes: bytes, productId: form.productId) {
                generatorId = ins.generatorID.rawValue
                generatorVersion = "file"
                conditions = ins.fileConditions
                if ins.check == .verified {
                    // 파일의 PC·제품이 선택과 같아야 한다
                    guard ins.pcScheme == ctx.pc.scheme, ins.pcNumber == ctx.pc.numberNormalized else {
                        throw StoreError.invalid(field: "pc", message: "파일의 PC 번호(\(ins.pcScheme.display(normalized: ins.pcNumber ?? "")))가 선택한 PC와 다릅니다. 해당 PC를 먼저 등록하고 고르세요.")
                    }
                    if ins.generatorID == .lmsLicenseV1, ins.productCode != ctx.product.v1ProductCode {
                        throw StoreError.invalid(field: "product", message: "파일의 제품 코드(\(ins.productCode ?? "?"))가 선택한 제품과 다릅니다.")
                    }
                    guard let s = ins.startsAt else { throw StoreError.invalid(field: "file", message: "파일의 시작 시각을 읽을 수 없습니다.") }
                    verification = .verified
                    detail = "서명 확인됨(\(ins.generatorID.displayName), key \(ins.keyId ?? "-"))"
                    keyId = ins.keyId
                    fileLicenseId = ins.licenseId
                    startsAt = s
                    expiresAt = ins.expiresAt
                    issuedAt = ins.issuedAt ?? issuedAt
                    signed = ins.signedMessage.map { String(decoding: $0, as: UTF8.self) }
                } else {
                    detail = "호환성 미검증: \(ins.check.displayText)"
                    conditions["file_license_id(미검증)"] = ins.licenseId ?? ""
                }
            } else {
                detail = "호환성 미검증: 알 수 없는 파일 형식"
                generatorId = GeneratorID.manual.rawValue
            }
        }
        if let e = expiresAt, e <= startsAt {
            throw StoreError.invalid(field: "expiresAt", message: "만료 시각은 시작 시각보다 늦어야 합니다.")
        }
        if let p = form.predecessor {
            let issues = predecessorIssues(p, ctx: ctx, newPcId: form.pcId)
            guard issues.isEmpty else { throw StoreError.generation(issues) }
        }
        conditions["product_name"] = ctx.product.name
        conditions["product_code_at_issue"] = ctx.product.code
        conditions["pc_scheme"] = ctx.pc.scheme.rawValue
        conditions["pc_number"] = ctx.pc.numberNormalized
        conditions["management_period"] = "[\(DBTime.string(startsAt)), \(expiresAt.map(DBTime.string) ?? "영구"))"
        if verification == .unverified {
            conditions["note"] = "관리상 기간입니다. 고객 프로그램이 이 기간을 강제하는지 확인되지 않았습니다."
        }
        let draft = LicenseDraft(
            customerId: form.customerId, productId: form.productId, pcId: form.pcId, issueMethod: .manual,
            verification: verification, verificationDetail: detail, generatorId: generatorId, generatorVersion: generatorVersion,
            keyId: keyId, fileLicenseId: fileLicenseId, startsAt: LicenseTime.truncated(startsAt),
            expiresAt: expiresAt.map(LicenseTime.truncated), issuedAt: LicenseTime.truncated(issuedAt),
            licenseFile: form.fileBytes, licenseFileName: form.fileName, signedPayload: signed, conditions: conditions,
            memo: form.memo, externalRef: form.externalRef.nilIfEmpty, importSource: nil, importKey: nil,
            requestToken: form.requestToken, predecessor: form.predecessor)
        return try save(draft, auditSummary: "수동 등록(\(verification.displayName)): \(ctx.product.name) / \(ctx.customer.name)")
    }

    // MARK: - 저장(공통)

    struct LicenseDraft {
        var customerId: Int64
        var productId: Int64
        var pcId: Int64
        var issueMethod: IssueMethod
        var verification: Verification
        var verificationDetail: String
        var generatorId: String
        var generatorVersion: String
        var keyId: String?
        var fileLicenseId: String?
        var startsAt: Date
        var expiresAt: Date?
        var issuedAt: Date
        var licenseFile: Data?
        var licenseFileName: String?
        var signedPayload: String?
        var conditions: [String: String]
        var memo: String
        var externalRef: String?
        var importSource: String?
        var importKey: String?
        var requestToken: String?
        var predecessor: Predecessor?
    }

    func save(_ d: LicenseDraft, auditSummary: String) throws -> License {
        do {
            return try db.write { db in
                if let token = d.requestToken,
                   let existing = try License.fetchOne(db, sql: "SELECT * FROM license WHERE requestToken = ?", arguments: [token]) {
                    return existing
                }
                return try insert(db, d, auditSummary: auditSummary)
            }
        } catch { throw StoreError.from(error) }
    }

    /// 트랜잭션 안에서 호출. 대체 처리 → 기간 중복 검사 → 저장 → 연결 → 감사 기록.
    func insert(_ db: Database, _ d: LicenseDraft, auditSummary: String) throws -> License {
        let t = now()
        let ts = DBTime.string(t)
        var excluded: [Int64] = []
        if let p = d.predecessor {
            guard let old = try License.fetchOne(db, key: p.licenseId) else { throw StoreError.notFound("이전 라이선스") }
            guard old.status == .issued else { throw StoreError.conflict("이전 라이선스가 이미 \(old.status.displayName) 상태입니다.") }
            if p.supersede {
                try db.execute(sql: "UPDATE license SET status = 'superseded', statusReason = ?, statusChangedAt = ?, updatedAt = ? WHERE id = ?",
                               arguments: ["\(p.kind.displayName): \(p.reason)", ts, ts, p.licenseId])
                excluded.append(p.licenseId)
                try failpoint?("after-supersede")
            }
        }
        let nos = try Self.overlaps(db, productId: d.productId, pcId: d.pcId, start: d.startsAt, end: d.expiresAt, excluding: excluded)
        guard nos.isEmpty else { throw StoreError.overlap(nos) }
        if let fid = d.fileLicenseId,
           let dup = try String.fetchOne(db, sql: "SELECT managementNo FROM license WHERE fileLicenseId = ?", arguments: [fid]) {
            throw StoreError.conflict("이미 등록된 라이선스 파일입니다(라이선스 ID 같음, 관리 번호 \(dup)).")
        }
        if let key = d.importKey,
           let dup = try String.fetchOne(db, sql: "SELECT managementNo FROM license WHERE importKey = ?", arguments: [key]) {
            throw StoreError.conflict("이미 가져온 기록입니다(관리 번호 \(dup)).")
        }
        try failpoint?("before-insert")
        let managementNo = try Self.nextManagementNo(db, now: t)
        var license = License(
            id: nil, managementNo: managementNo, customerId: d.customerId, productId: d.productId,
            pcId: d.pcId, status: .issued, issueMethod: d.issueMethod, verification: d.verification,
            verificationDetail: d.verificationDetail, generatorId: d.generatorId, generatorVersion: d.generatorVersion,
            keyId: d.keyId, fileLicenseId: d.fileLicenseId, startsAt: DBTime.string(d.startsAt),
            expiresAt: d.expiresAt.map(DBTime.string), issuedAt: DBTime.string(d.issuedAt), licenseFile: d.licenseFile,
            licenseFileName: d.licenseFileName, signedPayload: d.signedPayload,
            conditionsJSON: SnapshotJSON.encode(d.conditions), memo: d.memo, externalRef: d.externalRef,
            importSource: d.importSource, importKey: d.importKey, requestToken: d.requestToken, statusReason: nil,
            statusChangedAt: nil, createdAt: ts, updatedAt: ts)
        try license.insert(db)
        let newId = license.id!
        try Audit.log(db, entity: "license", id: newId, action: d.issueMethod.rawValue,
                      summary: "\(license.managementNo) \(auditSummary)", now: t)
        if let p = d.predecessor {
            var rel = LicenseRelation(fromLicenseId: p.licenseId, toLicenseId: newId, kind: p.kind, reason: p.reason, createdAt: ts)
            try rel.insert(db)
            if p.supersede {
                try Audit.log(db, entity: "license", id: p.licenseId, action: "supersede",
                              summary: "\(p.kind.displayName)로 대체됨 → \(license.managementNo)", reason: p.reason, now: t)
            }
            try Audit.log(db, entity: "license", id: newId, action: p.kind.rawValue,
                          summary: "\(p.kind.displayName): 이전 라이선스 #\(p.licenseId)", reason: p.reason, now: t)
        }
        return license
    }

    /// 같은 제품·PC에서 처리 상태가 발급됨이고 기간이 겹치는 라이선스의 관리 번호. 만료 없음 = 무한대.
    static func overlaps(_ db: Database, productId: Int64, pcId: Int64, start: Date, end: Date?, excluding: [Int64]) throws -> [String] {
        var sql = "SELECT managementNo FROM license WHERE productId = ? AND pcId = ? AND status = 'issued' AND (expiresAt IS NULL OR expiresAt > ?)"
        var args: [DatabaseValueConvertible?] = [productId, pcId, DBTime.string(start)]
        if let end {
            sql += " AND startsAt < ?"
            args.append(DBTime.string(end))
        }
        if !excluding.isEmpty {
            sql += " AND id NOT IN (\(excluding.map { _ in "?" }.joined(separator: ",")))"
            args += excluding.map { $0 as DatabaseValueConvertible? }
        }
        sql += " ORDER BY managementNo"
        return try String.fetchAll(db, sql: sql, arguments: StatementArguments(args))
    }

    /// 관리 번호 `L-YYYY-NNNNN` (서울 기준 연도, 연도별 일련번호)
    static func nextManagementNo(_ db: Database, now: Date) throws -> String {
        let year = LicenseTime.seoulDate(of: now).year
        let prefix = String(format: "L-%04d-", year)
        let last = try String.fetchOne(db, sql: "SELECT managementNo FROM license WHERE managementNo LIKE ? ORDER BY managementNo DESC LIMIT 1",
                                       arguments: [prefix + "%"])
        let n = last.flatMap { Int($0.dropFirst(prefix.count)) } ?? 0
        return prefix + String(format: "%05d", n + 1)
    }

    // MARK: - 갱신·PC 교체·취소

    /// 갱신 기본 제안: 시작 = 현재와 기존 만료 중 늦은 시각.
    /// 생성기가 미래 시작을 지원하지 않거나 기존이 영구면 시작 = 현재, 기존을 같은 트랜잭션에서 대체 처리.
    public func renewPlan(for old: License, generatorId: GeneratorID, termMonths: Int?) -> RenewPlan {
        let t = LicenseTime.truncated(now())
        let caps = GeneratorRegistry.generator(for: generatorId)?.capabilities
        let futureOK = caps?.futureStart ?? true
        func expiry(from start: Date) -> Date? {
            guard let m = termMonths, m > 0 else { return nil }
            return LicenseTime.endExclusive(lastDay: LicenseTime.lastDay(start: LicenseTime.seoulDate(of: start), months: m))
        }
        if let oldExp = old.expiresDate, futureOK {
            let start = max(t, oldExp)
            // 날짜 단위: 기존 만료(다음 날 00:00)가 새 시작일
            return RenewPlan(suggestedStart: start, suggestedExpiry: expiry(from: start), mustSupersede: false,
                             explanation: start > t
                                ? "기존 라이선스 만료 시각(\(LicenseTime.seoulDisplay(oldExp)))부터 이어서 시작합니다. 기존 라이선스는 만료까지 그대로 유효합니다."
                                : "기존 라이선스가 이미 만료되어 지금부터 시작합니다.")
        }
        let reason = old.isPerpetual
            ? "기존 라이선스가 영구라서 기간이 겹칩니다."
            : "이 생성 방식(\(generatorId.displayName))은 미래 시작을 지원하지 않아 발급 즉시 유효합니다."
        return RenewPlan(suggestedStart: t, suggestedExpiry: expiry(from: t), mustSupersede: old.status == .issued && old.effectiveStatus(now: t) != .expired,
                         explanation: "\(reason) 시작을 현재 시각으로 하고, 기존 라이선스를 같은 트랜잭션에서 '대체됨' 처리합니다. 확인 후 진행하세요.")
    }

    /// 발급 취소. 사유 필수, 기록은 삭제하지 않는다. 고객 PC에 이미 전달된 오프라인 라이선스는 원격으로 중지되지 않는다.
    public func cancel(licenseId: Int64, reason: String) throws {
        guard let r = reason.nilIfEmpty else { throw StoreError.invalid(field: "reason", message: "취소 사유를 입력하세요.") }
        do {
            try db.write { db in
                guard let l = try License.fetchOne(db, key: licenseId) else { throw StoreError.notFound("라이선스") }
                guard l.status == .issued else { throw StoreError.conflict("이미 \(l.status.displayName) 상태입니다.") }
                let ts = DBTime.string(now())
                try db.execute(sql: "UPDATE license SET status = 'cancelled', statusReason = ?, statusChangedAt = ?, updatedAt = ? WHERE id = ?",
                               arguments: [r, ts, ts, licenseId])
                try Audit.log(db, entity: "license", id: licenseId, action: "cancel", summary: "\(l.managementNo) 발급 취소", reason: r, now: now())
            }
        } catch { throw StoreError.from(error) }
    }

    /// 메모만 수정(내용·기간은 바꾸지 않는다)
    public func updateMemo(licenseId: Int64, memo: String) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE license SET memo = ?, updatedAt = ? WHERE id = ?", arguments: [memo, DBTime.string(now()), licenseId])
            try Audit.log(db, entity: "license", id: licenseId, action: "memo", summary: "메모 수정", now: now())
        }
    }

    /// 파일 재저장·복사 기록(재발급하지 않음)
    public func recordExport(licenseId: Int64, what: String) {
        try? db.write { db in
            try Audit.log(db, entity: "license", id: licenseId, action: "export", summary: what, now: now())
        }
    }
}
