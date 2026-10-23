import CryptoKit
import Foundation

/// ReviewCut 0.1.0 앱용 이전 형식. 기준: `../cut_review/src/main/license/core.ts`, `../cut_review/scripts/license/issue.ts`.
///
/// 파일: `{"payload":{…},"signature":Base64,"keyId":"prod-2026"}` (들여쓰기 2칸 + 줄바꿈)
/// 서명 대상: 정규화 JSON(payload) 그대로(접두어 없음). 영구만 지원(만료·시작 필드 없음).
public enum ReviewCutLegacy {
    public static let productId = "kr.reviewcut.app"
    public static let schema = 1
    public static let productMajor = 1
    public static let edition = "full"

    public struct Payload: Equatable, Sendable {
        public var licenseId: String
        public var installId: String
        public var licensee: String?
        /// 밀리초 포함 ISO 시각. 예) 2026-10-23T05:00:00.000Z
        public var issuedAt: String

        public init(licenseId: String, installId: String, licensee: String?, issuedAt: String) {
            self.licenseId = licenseId
            self.installId = installId
            self.licensee = licensee
            self.issuedAt = issuedAt
        }

        /// issue.ts와 같은 키 순서. licensee가 없으면 필드 자체를 넣지 않는다.
        public var json: JSONValue {
            var pairs: [(String, JSONValue)] = [
                ("schema", .number(JSONNumber(ReviewCutLegacy.schema))),
                ("productId", .string(ReviewCutLegacy.productId)),
                ("productMajor", .number(JSONNumber(ReviewCutLegacy.productMajor))),
                ("licenseId", .string(licenseId)),
                ("installId", .string(installId)),
                ("edition", .string(ReviewCutLegacy.edition)),
            ]
            if let l = licensee { pairs.append(("licensee", .string(l))) }
            pairs.append(("issuedAt", .string(issuedAt)))
            return .object(JSONObject(pairs))
        }
    }

    public static func signingMessage(payload: JSONValue) throws -> Data {
        try JSONWriter.canonicalData(payload)
    }

    public static func renderFile(payload: JSONValue, signature: Data, keyId: String) -> Data {
        let doc = JSONValue.object(JSONObject([
            ("payload", payload),
            ("signature", .string(signature.base64EncodedString())),
            ("keyId", .string(keyId)),
        ]))
        return Data((JSONWriter.pretty(doc) + "\n").utf8)
    }
}

public struct ReviewCutLegacyGenerator: LicenseGenerator {
    public let id = GeneratorID.reviewcutLegacy
    public let version = "0.1.0"
    public let capabilities = GeneratorCapabilities(perpetual: true, term: false, futureStart: false, scheme: .reviewcutInstallId)

    public init() {}

    public func validate(_ r: LicenseRequest, now: Date) -> [ValidationIssue] {
        var issues = commonIssues(r, now: now)
        if let l = r.licensee {
            let s = l.trimmingCharacters(in: .whitespacesAndNewlines)
            if TextRules.length(s) > 100 { issues.append(.init(.licensee, "고객 표시명은 100자 이하여야 합니다.")) }
            if TextRules.hasControl(s) { issues.append(.init(.licensee, "고객 표시명에 줄바꿈·제어 문자를 넣을 수 없습니다.")) }
        }
        if !TextRules.isLowerUUID(r.licenseId) { issues.append(.init(.general, "라이선스 ID 형식 오류")) }
        return issues
    }

    public func makePayload(_ r: LicenseRequest) -> ReviewCutLegacy.Payload {
        let licensee = r.licensee?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReviewCutLegacy.Payload(
            licenseId: r.licenseId,
            installId: r.pcNormalized,
            licensee: (licensee?.isEmpty ?? true) ? nil : licensee,
            issuedAt: LicenseTime.utcMillisString(r.issuedAt))
    }

    public func generate(_ r: LicenseRequest, signing: SigningMaterial, now: Date) throws -> GeneratedLicense {
        var issues = validate(r, now: now)
        if signing.keyId.isEmpty { issues.append(.init(.key, "서명 키 이름(keyId)이 필요합니다.")) }
        guard issues.isEmpty else { throw GenerationError(issues) }
        let payload = makePayload(r)
        let message = try ReviewCutLegacy.signingMessage(payload: payload.json)
        let signature = try signing.privateKey.signature(for: message)
        let file = ReviewCutLegacy.renderFile(payload: payload.json, signature: signature, keyId: signing.keyId)
        // 파일의 issuedAt은 밀리초까지 기록되지만 관리 기준 시작은 초 단위로 맞춘다.
        let issued = LicenseTime.parseUTCMillis(payload.issuedAt) ?? r.issuedAt
        return GeneratedLicense(
            generatorID: id, generatorVersion: version, fileBytes: file,
            fileName: "license-\(payload.installId).json",
            licenseIdInFile: payload.licenseId, keyId: signing.keyId, signedMessage: message,
            startsAt: LicenseTime.truncated(issued), expiresAt: nil,
            fileConditions: [
                "format": "reviewcut legacy (schema 1)",
                "keyId": signing.keyId,
                "productId": ReviewCutLegacy.productId,
                "productMajor": String(ReviewCutLegacy.productMajor),
                "installId": payload.installId,
                "edition": ReviewCutLegacy.edition,
                "licensee": payload.licensee ?? "(없음)",
                "issuedAt": payload.issuedAt,
                "expires": "없음(영구)",
            ])
    }

    public func inspect(fileBytes: Data, publicKeys: [PublicKeyRef]) -> InspectedLicense? {
        guard let raw = try? JSONParser.parse(fileBytes), case .object(let doc) = raw,
              doc["format"] == nil, doc["payload"] != nil, doc["keyId"] != nil else { return nil }
        var r = InspectedLicense(generatorID: id, check: .format, pcScheme: .reviewcutInstallId)
        guard let sigText = doc["signature"]?.stringValue, let keyId = doc["keyId"]?.stringValue,
              case .object(let p)? = doc["payload"] else { return r }
        r.keyId = keyId
        // 내용 미리 채우기(서명 확인 전에도 보여줄 수 있게)
        r.licenseId = p["licenseId"]?.stringValue
        r.pcNumber = p["installId"]?.stringValue
        r.licensee = p["licensee"]?.stringValue
        r.edition = p["edition"]?.stringValue
        r.productCode = p["productId"]?.stringValue
        if let issued = p["issuedAt"]?.stringValue.flatMap(LicenseTime.parseUTCMillis) {
            r.issuedAt = issued
            r.startsAt = LicenseTime.truncated(issued)
        }
        r.isPerpetual = true
        r.fileConditions = [
            "format": "reviewcut legacy",
            "keyId": keyId,
            "installId": r.pcNumber ?? "",
            "licensee": r.licensee ?? "(없음)",
            "issuedAt": p["issuedAt"]?.stringValue ?? "",
            "expires": "없음(영구)",
        ]
        r.signedMessage = try? ReviewCutLegacy.signingMessage(payload: .object(p))

        guard let ref = publicKeys.first(where: { $0.keyId == keyId }), let key = Ed25519Keys.publicKey(raw: ref.raw) else {
            r.check = .unknownKey
            return r
        }
        guard let message = r.signedMessage, let sig = Data(base64Encoded: sigText),
              key.isValidSignature(sig, for: message) else {
            r.check = .badSignature
            return r
        }
        // core.ts verifyLicense와 같은 내용 검사
        guard p["schema"]?.numberValue?.doubleValue == Double(ReviewCutLegacy.schema),
              p["productId"]?.stringValue == ReviewCutLegacy.productId,
              p["productMajor"]?.numberValue?.doubleValue == Double(ReviewCutLegacy.productMajor),
              r.pcNumber != nil, p["edition"]?.stringValue == ReviewCutLegacy.edition,
              r.licenseId != nil, p["issuedAt"]?.stringValue != nil else {
            r.check = .format
            return r
        }
        r.check = .verified
        return r
    }
}
