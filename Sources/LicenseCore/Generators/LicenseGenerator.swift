import CryptoKit
import Foundation

/// 라이선스 생성 방식
public enum GeneratorID: String, CaseIterable, Codable, Sendable, Identifiable {
    case lmsLicenseV1 = "lms-license-v1"
    case reviewcutLegacy = "reviewcut-legacy"
    case rentaldeskLegacy = "rentaldesk-legacy"
    /// 생성 방식 없음(외부 라이선스를 수동 등록만 함)
    case manual = "manual"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .lmsLicenseV1: return "공통 형식 v1"
        case .reviewcutLegacy: return "ReviewCut 이전 형식(0.1)"
        case .rentaldeskLegacy: return "RentalDesk 이전 형식(1.0)"
        case .manual: return "수동 등록 전용"
        }
    }

    /// 이 방식이 받는 PC 번호 체계. 수동은 모든 체계.
    public var scheme: PcScheme? {
        switch self {
        case .lmsLicenseV1: return .lmsPcV1
        case .reviewcutLegacy: return .reviewcutInstallId
        case .rentaldeskLegacy: return .rentaldeskMachineV0
        case .manual: return nil
        }
    }
}

/// 생성기가 지원하는 조건
public struct GeneratorCapabilities: Equatable, Sendable {
    public let perpetual: Bool
    public let term: Bool
    public let futureStart: Bool
    public let scheme: PcScheme

    public init(perpetual: Bool, term: Bool, futureStart: Bool, scheme: PcScheme) {
        self.perpetual = perpetual
        self.term = term
        self.futureStart = futureStart
        self.scheme = scheme
    }
}

/// 발급 입력(생성기 공통)
public struct LicenseRequest: Equatable, Sendable {
    /// 공통 형식 제품 코드(`^[A-Z][A-Z0-9_]{1,31}$`). 이전 형식에서는 쓰지 않는다.
    public var productCode: String
    public var pcScheme: PcScheme
    public var pcRaw: String
    public var pcNormalized: String
    public var issuedAt: Date
    public var startsAt: Date
    /// 관리 기준 만료 시각(미포함). nil이면 영구.
    public var expiresAt: Date?
    /// 고객 표시명(상호 등). 연락처·이메일 금지.
    public var licensee: String?
    public var edition: String
    /// 사용 가능한 최고 `주.부` 버전. nil이면 제한 없음(공통 형식만).
    public var maxVersion: String?
    public var options: [String: String]
    /// 파일 안에 들어갈 라이선스 ID(소문자 UUID)
    public var licenseId: String

    public init(productCode: String, pcScheme: PcScheme, pcRaw: String, pcNormalized: String, issuedAt: Date,
                startsAt: Date, expiresAt: Date?, licensee: String?, edition: String, maxVersion: String?,
                options: [String: String] = [:], licenseId: String = UUID().uuidString.lowercased()) {
        self.productCode = productCode
        self.pcScheme = pcScheme
        self.pcRaw = pcRaw
        self.pcNormalized = pcNormalized
        self.issuedAt = issuedAt
        self.startsAt = startsAt
        self.expiresAt = expiresAt
        self.licensee = licensee
        self.edition = edition
        self.maxVersion = maxVersion
        self.options = options
        self.licenseId = licenseId
    }
}

/// 서명 키(비밀키는 메모리에서만 다룬다)
public struct SigningMaterial {
    public let keyId: String
    public let privateKey: Curve25519.Signing.PrivateKey

    public init(keyId: String, privateKey: Curve25519.Signing.PrivateKey) {
        self.keyId = keyId
        self.privateKey = privateKey
    }
}

/// 검증용 공개키
public struct PublicKeyRef: Equatable, Sendable {
    public let keyId: String
    public let raw: Data

    public init(keyId: String, raw: Data) {
        self.keyId = keyId
        self.raw = raw
    }
}

/// 생성 결과
public struct GeneratedLicense: Equatable, Sendable {
    public let generatorID: GeneratorID
    public let generatorVersion: String
    /// 라이선스 파일 바이트(UTF-8 JSON)
    public let fileBytes: Data
    public let fileName: String
    public let licenseIdInFile: String
    public let keyId: String?
    /// 서명 대상 바이트
    public let signedMessage: Data
    /// 관리 기준 시작·만료(미포함)
    public let startsAt: Date
    public let expiresAt: Date?
    /// 파일에 기록된 조건 원문(스냅샷용). 예: expires_at_utc = 23:59:59
    public let fileConditions: [String: String]

    public var fileText: String { String(decoding: fileBytes, as: UTF8.self) }
    public var signedMessageText: String { String(decoding: signedMessage, as: UTF8.self) }
}

/// 입력 검증 결과(사용자에게 그대로 보여줄 수 있는 문구)
public struct ValidationIssue: Equatable, Sendable, Identifiable {
    public enum Field: String, Sendable {
        case pc, period, start, expiry, licensee, edition, maxVersion, productCode, options, key, general
    }

    public let field: Field
    public let message: String
    public var id: String { field.rawValue + ":" + message }

    public init(_ field: Field, _ message: String) {
        self.field = field
        self.message = message
    }
}

public struct GenerationError: Error, LocalizedError, Equatable {
    public let issues: [ValidationIssue]
    public init(_ issues: [ValidationIssue]) { self.issues = issues }
    public var errorDescription: String? { issues.map(\.message).joined(separator: "\n") }
}

/// 파일 검사 결과 코드(서명까지)
public enum SignatureCheck: String, Codable, Sendable {
    /// 형식·서명 모두 확인됨
    case verified
    /// 파일 형식 오류
    case format
    /// 해당 key_id 공개키가 등록되어 있지 않음
    case unknownKey = "unknown_key"
    /// 서명 불일치
    case badSignature = "bad_signature"

    public var displayText: String {
        switch self {
        case .verified: return "서명 확인됨"
        case .format: return "파일 형식 오류"
        case .unknownKey: return "등록된 공개키 없음(key_id 불일치)"
        case .badSignature: return "서명 불일치"
        }
    }
}

/// 라이선스 파일을 읽어 얻은 내용
public struct InspectedLicense: Equatable, Sendable {
    public var generatorID: GeneratorID
    public var check: SignatureCheck
    public var keyId: String?
    public var licenseId: String?
    public var pcScheme: PcScheme
    /// 파일 안 PC 번호(정규화 값)
    public var pcNumber: String?
    public var productCode: String?
    public var issuedAt: Date?
    /// 관리 기준 시작·만료(미포함)
    public var startsAt: Date?
    public var expiresAt: Date?
    public var isPerpetual: Bool
    public var licensee: String?
    public var edition: String?
    public var maxVersion: String?
    public var signedMessage: Data?
    /// 파일에 기록된 조건 원문
    public var fileConditions: [String: String]

    public init(generatorID: GeneratorID, check: SignatureCheck, pcScheme: PcScheme) {
        self.generatorID = generatorID
        self.check = check
        self.pcScheme = pcScheme
        self.isPerpetual = false
        self.fileConditions = [:]
    }
}

/// 내장 라이선스 생성기. 관리 기능과 생성 알고리즘을 분리한다.
public protocol LicenseGenerator {
    var id: GeneratorID { get }
    var version: String { get }
    var capabilities: GeneratorCapabilities { get }

    /// 발급 전 입력 검증. 빈 배열이면 통과.
    func validate(_ request: LicenseRequest, now: Date) -> [ValidationIssue]

    /// 서명된 라이선스 파일을 만든다. 입력이 규칙을 어기면 `GenerationError`.
    func generate(_ request: LicenseRequest, signing: SigningMaterial, now: Date) throws -> GeneratedLicense

    /// 파일이 이 생성기 형식이면 내용과 서명 검사 결과를, 다른 형식이면 nil.
    func inspect(fileBytes: Data, publicKeys: [PublicKeyRef]) -> InspectedLicense?
}

extension LicenseGenerator {
    /// 공통 검사: 체계·기간·영구/기간제/미래 시작 지원 여부
    func commonIssues(_ r: LicenseRequest, now: Date) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let caps = capabilities
        if r.pcScheme != caps.scheme {
            issues.append(.init(.pc, "\(id.displayName)은(는) \(caps.scheme.displayName) PC 번호에만 발급할 수 있습니다."))
        } else if !caps.scheme.isValid(normalized: r.pcNormalized) {
            issues.append(.init(.pc, caps.scheme.formatHint))
        }
        if r.expiresAt == nil && !caps.perpetual {
            issues.append(.init(.period, "\(id.displayName)은(는) 영구 라이선스를 지원하지 않습니다."))
        }
        if let exp = r.expiresAt {
            if !caps.term {
                issues.append(.init(.period, "\(id.displayName)은(는) 영구 라이선스만 지원합니다(파일에 만료 정보를 넣을 수 없음)."))
            } else if exp <= r.startsAt {
                issues.append(.init(.expiry, "만료 시각은 시작 시각보다 늦어야 합니다."))
            }
        }
        // 미래 시작을 지원하지 않는 생성기: 시작 = 발급 시각(1분 이내 오차 허용)
        if !caps.futureStart && r.startsAt.timeIntervalSince(now) > 60 {
            issues.append(.init(.start, "\(id.displayName)은(는) 미래 시작을 지원하지 않습니다. 발급 즉시 유효합니다. 시작 시각을 현재로 하세요."))
        }
        return issues
    }
}

/// 내장 생성기 목록
public enum GeneratorRegistry {
    public static let v1 = LmsLicenseV1Generator()
    public static let reviewCutLegacy = ReviewCutLegacyGenerator()
    public static let rentalDeskLegacy = RentalDeskLegacyGenerator()

    public static let all: [LicenseGenerator] = [v1, reviewCutLegacy, rentalDeskLegacy]

    public static func generator(for id: GeneratorID) -> LicenseGenerator? {
        all.first { $0.id == id }
    }

    public static func generator(forScheme scheme: PcScheme) -> LicenseGenerator? {
        all.first { $0.capabilities.scheme == scheme }
    }

    /// 형식을 자동 판별해 검사한다. 어떤 형식도 아니면 nil(형식을 모름 → 호환성 미검증).
    public static func inspectAny(fileBytes: Data, publicKeys: [PublicKeyRef]) -> InspectedLicense? {
        for g in all {
            if let r = g.inspect(fileBytes: fileBytes, publicKeys: publicKeys) { return r }
        }
        return nil
    }
}
