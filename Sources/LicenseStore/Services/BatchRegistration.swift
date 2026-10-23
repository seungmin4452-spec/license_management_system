import Foundation
import GRDB
import LicenseCore

/// 라이선스 파일 여러 개 일괄 수동 등록(ReviewCut처럼 발급 내역 파일이 없는 제품용)
public struct BatchFileItem: Identifiable, Equatable {
    public enum CustomerChoice: Equatable {
        case existing(Int64)
        case new(String)
    }

    public var id = UUID()
    public var fileName: String
    public var fileBytes: Data
    public var inspected: InspectedLicense?
    public var customer: CustomerChoice
    /// 이미 등록된 PC(파일의 PC 번호로 찾음)
    public var existingPcId: Int64?
    public var existingPcOwnerId: Int64?
    public var existingPcOwnerName: String?
    public var problems: [String] = []
    public var alreadyRegistered: String?

    public var isVerified: Bool { inspected?.check == .verified }
}

extension LicenseService {
    /// 파일들을 읽어 미리보기 항목을 만든다. 고객은 파일의 PC가 이미 등록되어 있으면 그 소유 고객, 아니면 표시명으로 새 고객.
    public func prepareBatch(files: [(name: String, data: Data)], productId: Int64) throws -> [BatchFileItem] {
        let product = try db.read { db in try Product.fetchOne(db, key: productId) }
        guard let product else { throw StoreError.notFound("제품") }
        return try files.map { f -> BatchFileItem in
            let ins = inspect(fileBytes: f.data, productId: productId)
            var item = BatchFileItem(fileName: f.name, fileBytes: f.data, inspected: ins,
                                     customer: .new(ins?.licensee?.nilIfEmpty ?? (f.name as NSString).deletingPathExtension))
            guard let ins else {
                item.problems.append("알 수 없는 파일 형식입니다(호환성 미검증으로 등록하려면 개별 수동 등록을 사용하세요).")
                return item
            }
            if ins.check != .verified { item.problems.append("서명 검증 실패: \(ins.check.displayText)") }
            if ins.generatorID == .lmsLicenseV1, ins.productCode != product.v1ProductCode {
                item.problems.append("다른 제품의 라이선스입니다(\(ins.productCode ?? "?")).")
            }
            if let number = ins.pcNumber {
                try db.read { db in
                    if let pc = try CustomerPC.fetchOne(db, sql: "SELECT * FROM customer_pc WHERE scheme = ? AND numberNormalized = ?",
                                                        arguments: [ins.pcScheme.rawValue, number]) {
                        item.existingPcId = pc.id
                        item.existingPcOwnerId = pc.customerId
                        item.existingPcOwnerName = try String.fetchOne(db, sql: "SELECT name FROM customer WHERE id = ?", arguments: [pc.customerId])
                        item.customer = .existing(pc.customerId)
                    }
                    // 서명이 확인된 파일만 '이미 등록됨'으로 건너뛴다(변조 파일이 기존 ID를 흉내 내도 오류로 표시)
                    if ins.check == .verified, let lid = ins.licenseId,
                       let no = try String.fetchOne(db, sql: "SELECT managementNo FROM license WHERE fileLicenseId = ?", arguments: [lid]) {
                        item.alreadyRegistered = no
                    }
                }
            } else {
                item.problems.append("파일에서 PC 번호를 읽을 수 없습니다.")
            }
            return item
        }
    }

    /// 일괄 등록. 서명 검증을 통과한 파일만 받으며, 하나라도 실패하면 전체를 저장하지 않는다.
    /// 이미 등록된 라이선스 ID는 건너뛴다. 등록한 수를 돌려준다.
    @discardableResult
    public func commitBatch(_ items: [BatchFileItem], productId: Int64) throws -> Int {
        let bad = items.filter { $0.alreadyRegistered == nil && (!$0.problems.isEmpty || !$0.isVerified) }
        guard bad.isEmpty else {
            throw StoreError.invalid(field: nil, message: "검증에 실패한 파일이 있어 저장하지 않았습니다: \(bad.map(\.fileName).joined(separator: ", "))")
        }
        let productName = try db.read { db in try String.fetchOne(db, sql: "SELECT name FROM product WHERE id = ?", arguments: [productId]) } ?? "?"
        do {
            return try db.write { db in
                let t = now()
                let ts = DBTime.string(t)
                var count = 0
                var newCustomers: [String: Int64] = [:]
                for item in items where item.alreadyRegistered == nil {
                    guard let ins = item.inspected, let number = ins.pcNumber, let start = ins.startsAt else { continue }
                    // 고객
                    let cid: Int64
                    switch item.customer {
                    case .existing(let id):
                        guard try Customer.fetchOne(db, key: id) != nil else { throw StoreError.notFound("고객 #\(id)") }
                        cid = id
                    case .new(let rawName):
                        let name = rawName.trimmed
                        guard !name.isEmpty else { throw StoreError.invalid(field: nil, message: "\(item.fileName): 고객명을 입력하세요.") }
                        if let id = newCustomers[name] { cid = id } else {
                            var c = Customer(name: name, createdAt: ts, updatedAt: ts)
                            try c.insert(db)
                            try Audit.log(db, entity: "customer", id: c.id!, action: "create", summary: "일괄 등록으로 고객 생성: \(name)", now: t)
                            newCustomers[name] = c.id!
                            cid = c.id!
                        }
                    }
                    // PC
                    let pcId: Int64
                    if let pc = try CustomerPC.fetchOne(db, sql: "SELECT * FROM customer_pc WHERE scheme = ? AND numberNormalized = ?",
                                                        arguments: [ins.pcScheme.rawValue, number]) {
                        guard pc.customerId == cid else {
                            let owner = try String.fetchOne(db, sql: "SELECT name FROM customer WHERE id = ?", arguments: [pc.customerId]) ?? "?"
                            throw StoreError.invalid(field: nil, message: "\(item.fileName): PC가 다른 고객(\(owner))에 등록되어 있습니다.")
                        }
                        pcId = pc.id!
                    } else {
                        var pc = CustomerPC(customerId: cid, scheme: ins.pcScheme, numberRaw: number, numberNormalized: number,
                                            createdAt: ts, updatedAt: ts)
                        try pc.insert(db)
                        try Audit.log(db, entity: "customer_pc", id: pc.id!, action: "create",
                                      summary: "일괄 등록으로 PC 등록: \(ins.pcScheme.rawValue) \(Mask.pc(number))", now: t)
                        pcId = pc.id!
                    }
                    var conditions = ins.fileConditions
                    conditions["product_name"] = productName
                    conditions["pc_scheme"] = ins.pcScheme.rawValue
                    conditions["pc_number"] = number
                    let draft = LicenseDraft(
                        customerId: cid, productId: productId, pcId: pcId, issueMethod: .manual, verification: .verified,
                        verificationDetail: "서명 확인됨(\(ins.generatorID.displayName), key \(ins.keyId ?? "-"))",
                        generatorId: ins.generatorID.rawValue, generatorVersion: "file", keyId: ins.keyId,
                        fileLicenseId: ins.licenseId, startsAt: start, expiresAt: ins.expiresAt,
                        issuedAt: LicenseTime.truncated(ins.issuedAt ?? start), licenseFile: item.fileBytes,
                        licenseFileName: item.fileName, signedPayload: ins.signedMessage.map { String(decoding: $0, as: UTF8.self) },
                        conditions: conditions, memo: "", externalRef: nil, importSource: "일괄 등록", importKey: nil,
                        requestToken: nil, predecessor: nil)
                    _ = try insert(db, draft, auditSummary: "일괄 수동 등록: \(item.fileName)")
                    count += 1
                }
                return count
            }
        } catch { throw StoreError.from(error) }
    }
}
