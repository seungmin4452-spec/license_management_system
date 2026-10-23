import Foundation
import GRDB
import LicenseCore

// 모든 시각 열: UTC `YYYY-MM-DDTHH:MM:SSZ` 문자열. 변환은 `DBTime`.

public enum DBTime {
    public static func string(_ date: Date) -> String { LicenseTime.utcString(date) }
    public static func date(_ string: String) -> Date { LicenseTime.parseUTC(string) ?? Date(timeIntervalSince1970: 0) }
    public static func date(_ string: String?) -> Date? { string.flatMap(LicenseTime.parseUTC) }
}

public struct Product: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "product"
    public var id: Int64?
    /// 관리용 제품 코드(내부 식별). 공통 형식 파일의 제품 코드는 `v1ProductCode`.
    public var code: String
    public var name: String
    public var description: String
    /// 판매 중
    public var isActive: Bool
    /// 보관(라이선스가 있는 제품은 삭제하지 않고 보관)
    public var isArchived: Bool
    public var v1ProductCode: String?
    public var defaultEdition: String
    public var defaultMaxVersion: String?
    /// 기본 기간(개월). nil이면 영구.
    public var defaultTermMonths: Int?
    public var settingsJSON: String
    public var createdAt: String
    public var updatedAt: String

    public init(id: Int64? = nil, code: String, name: String, description: String = "", isActive: Bool = true,
                isArchived: Bool = false, v1ProductCode: String? = nil, defaultEdition: String = "standard",
                defaultMaxVersion: String? = nil, defaultTermMonths: Int? = nil, settingsJSON: String = "{}",
                createdAt: String = "", updatedAt: String = "") {
        self.id = id
        self.code = code
        self.name = name
        self.description = description
        self.isActive = isActive
        self.isArchived = isArchived
        self.v1ProductCode = v1ProductCode
        self.defaultEdition = defaultEdition
        self.defaultMaxVersion = defaultMaxVersion
        self.defaultTermMonths = defaultTermMonths
        self.settingsJSON = settingsJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct ProductGenerator: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "product_generator"
    public var id: Int64?
    public var productId: Int64
    public var generatorId: String
    public var generatorVersion: String
    public var isEnabled: Bool
    public var createdAt: String
    public var updatedAt: String

    public init(id: Int64? = nil, productId: Int64, generatorId: GeneratorID, generatorVersion: String,
                isEnabled: Bool = true, createdAt: String = "", updatedAt: String = "") {
        self.id = id
        self.productId = productId
        self.generatorId = generatorId.rawValue
        self.generatorVersion = generatorVersion
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var generator: GeneratorID? { GeneratorID(rawValue: generatorId) }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public enum SigningKeyStatus: String, Codable, Sendable {
    case active, archived
    public var displayName: String { self == .active ? "사용" : "보관" }
}

public enum SigningKeyOrigin: String, Codable, Sendable {
    /// 이 앱에서 새로 만든 키
    case generated
    /// 기존 비밀키를 가져옴
    case imported
    /// 고객 앱 공개키만 등록(비밀키는 아직 없음)
    case expected

    public var displayName: String {
        switch self {
        case .generated: return "앱에서 생성"
        case .imported: return "기존 키 가져옴"
        case .expected: return "공개키만 등록됨"
        }
    }
}

/// 서명 키(공개키·key_id만). 비밀키는 키체인 `keychainAccount` 항목에만 있다.
public struct SigningKey: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "signing_key"
    public var id: Int64?
    public var productId: Int64
    public var keyId: String
    public var publicKeyHex: String
    public var status: SigningKeyStatus
    public var origin: SigningKeyOrigin
    public var keychainAccount: String
    public var note: String
    public var createdAt: String
    public var updatedAt: String

    public init(id: Int64? = nil, productId: Int64, keyId: String, publicKeyHex: String, status: SigningKeyStatus = .active,
                origin: SigningKeyOrigin, keychainAccount: String = UUID().uuidString, note: String = "",
                createdAt: String = "", updatedAt: String = "") {
        self.id = id
        self.productId = productId
        self.keyId = keyId
        self.publicKeyHex = publicKeyHex
        self.status = status
        self.origin = origin
        self.keychainAccount = keychainAccount
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var publicKeyRaw: Data { TextRules.dataFromHex(publicKeyHex) ?? Data() }
    public var publicKeyRef: PublicKeyRef { PublicKeyRef(keyId: keyId, raw: publicKeyRaw) }
    public var publicKeyPEM: String { Ed25519Keys.spkiPEM(publicKeyRaw: publicKeyRaw) }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct Customer: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "customer"
    public var id: Int64?
    /// 고객명 또는 업체명
    public var name: String
    public var contactPerson: String
    public var phone: String
    public var email: String
    public var memo: String
    public var isArchived: Bool
    public var createdAt: String
    public var updatedAt: String

    public init(id: Int64? = nil, name: String, contactPerson: String = "", phone: String = "", email: String = "",
                memo: String = "", isArchived: Bool = false, createdAt: String = "", updatedAt: String = "") {
        self.id = id
        self.name = name
        self.contactPerson = contactPerson
        self.phone = phone
        self.email = email
        self.memo = memo
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct CustomerPC: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "customer_pc"
    public var id: Int64?
    public var customerId: Int64
    public var scheme: PcScheme
    /// 고객이 보낸 원문(앞뒤 공백만 제거)
    public var numberRaw: String
    /// 체계별 정규화 값(규칙이 없는 체계는 원문과 같음)
    public var numberNormalized: String
    public var alias: String
    public var memo: String
    public var createdAt: String
    public var updatedAt: String

    public init(id: Int64? = nil, customerId: Int64, scheme: PcScheme, numberRaw: String, numberNormalized: String,
                alias: String = "", memo: String = "", createdAt: String = "", updatedAt: String = "") {
        self.id = id
        self.customerId = customerId
        self.scheme = scheme
        self.numberRaw = numberRaw
        self.numberNormalized = numberNormalized
        self.alias = alias
        self.memo = memo
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 화면 표시 형식(하이픈 묶음)
    public var displayNumber: String { scheme.display(normalized: numberNormalized) }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct PcLink: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "pc_link"
    public var id: Int64?
    public var pcAId: Int64
    public var pcBId: Int64
    public var memo: String
    public var createdAt: String

    public init(id: Int64? = nil, pcAId: Int64, pcBId: Int64, memo: String = "", createdAt: String = "") {
        self.id = id
        self.pcAId = pcAId
        self.pcBId = pcBId
        self.memo = memo
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// 저장되는 처리 상태
public enum ProcessingStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    case issued, cancelled, superseded
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .issued: return "발급됨"
        case .cancelled: return "취소됨"
        case .superseded: return "대체됨"
        }
    }
}

/// 시간으로 계산하는 유효 상태(조회 시 계산). 취소·대체가 우선한다.
public enum EffectiveStatus: String, CaseIterable, Sendable, Identifiable {
    case notYetValid, valid, expired, cancelled, superseded
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .notYetValid: return "사용 전"
        case .valid: return "유효"
        case .expired: return "만료"
        case .cancelled: return "취소됨"
        case .superseded: return "대체됨"
        }
    }

    public static func compute(status: ProcessingStatus, startsAt: Date, expiresAt: Date?, now: Date) -> EffectiveStatus {
        switch status {
        case .cancelled: return .cancelled
        case .superseded: return .superseded
        case .issued:
            if now < startsAt { return .notYetValid }
            if let e = expiresAt, now >= e { return .expired }
            return .valid
        }
    }
}

public enum IssueMethod: String, Codable, Sendable {
    case auto, manual, `import`
    public var displayName: String {
        switch self {
        case .auto: return "자동 발급"
        case .manual: return "수동 등록"
        case .import: return "가져오기"
        }
    }
}

public enum Verification: String, Codable, Sendable {
    case verified, unverified
    public var displayName: String { self == .verified ? "호환성 검증됨" : "호환성 미검증" }
}

public struct License: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "license"
    public var id: Int64?
    public var managementNo: String
    public var customerId: Int64
    public var productId: Int64
    public var pcId: Int64
    public var status: ProcessingStatus
    public var issueMethod: IssueMethod
    public var verification: Verification
    public var verificationDetail: String
    public var generatorId: String
    public var generatorVersion: String
    public var keyId: String?
    /// 파일 안의 라이선스 ID(고유)
    public var fileLicenseId: String?
    public var startsAt: String
    /// nil = 영구
    public var expiresAt: String?
    public var issuedAt: String
    public var licenseFile: Data?
    public var licenseFileName: String?
    /// 서명 대상 원문(UTF-8)
    public var signedPayload: String?
    /// 발급 당시 조건 스냅샷(JSON)
    public var conditionsJSON: String
    public var memo: String
    public var externalRef: String?
    public var importSource: String?
    public var importKey: String?
    public var requestToken: String?
    public var statusReason: String?
    public var statusChangedAt: String?
    public var createdAt: String
    public var updatedAt: String

    public var startsDate: Date { DBTime.date(startsAt) }
    public var expiresDate: Date? { DBTime.date(expiresAt) }
    public var issuedDate: Date { DBTime.date(issuedAt) }
    public var isPerpetual: Bool { expiresAt == nil }
    public var generator: GeneratorID? { GeneratorID(rawValue: generatorId) }

    public func effectiveStatus(now: Date) -> EffectiveStatus {
        EffectiveStatus.compute(status: status, startsAt: startsDate, expiresAt: expiresDate, now: now)
    }

    public var conditions: [String: String] {
        guard case .object(let o)? = try? JSONParser.parse(conditionsJSON) else { return [:] }
        var out: [String: String] = [:]
        for e in o.entries { out[e.key] = e.value.stringValue ?? "" }
        return out
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public enum RelationKind: String, Codable, Sendable {
    case renewal, replacement
    public var displayName: String { self == .renewal ? "갱신" : "PC 교체" }
}

public struct LicenseRelation: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "license_relation"
    public var id: Int64?
    public var fromLicenseId: Int64
    public var toLicenseId: Int64
    public var kind: RelationKind
    public var reason: String
    public var createdAt: String

    public init(id: Int64? = nil, fromLicenseId: Int64, toLicenseId: Int64, kind: RelationKind, reason: String, createdAt: String) {
        self.id = id
        self.fromLicenseId = fromLicenseId
        self.toLicenseId = toLicenseId
        self.kind = kind
        self.reason = reason
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct AuditLog: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "audit_log"
    public var id: Int64?
    public var entityType: String
    public var entityId: Int64
    public var action: String
    public var at: String
    public var summary: String
    public var reason: String

    public init(id: Int64? = nil, entityType: String, entityId: Int64, action: String, at: String, summary: String, reason: String = "") {
        self.id = id
        self.entityType = entityType
        self.entityId = entityId
        self.action = action
        self.at = at
        self.summary = summary
        self.reason = reason
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// JSON 문자열(스냅샷·설정용). 키 정렬, 들여쓰기 없음.
enum SnapshotJSON {
    static func encode(_ dict: [String: String]) -> String {
        var obj = JSONObject()
        for k in dict.keys.sorted(by: JSONWriter.codePointLess) { obj[k] = .string(dict[k]!) }
        return (try? JSONWriter.canonical(.object(obj))) ?? "{}"
    }
}
