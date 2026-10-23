import CryptoKit
import Foundation

/// RentalDesk 1.0.0 앱용 이전 형식. 기준: `../rental_management_system/src/rentdesk/services/licensing.py`,
/// `../rental_management_system/scripts/generate_license.py`.
///
/// 파일: `{"license":{…},"signature":Base64}` (들여쓰기 2칸, 한글 그대로, 끝 줄바꿈 없음)
/// 서명 대상: `json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)` 의 UTF-8 바이트.
/// 만료 표기 차이: 파일에는 마지막 사용일 서울 23:59:59를 쓰고, 앱은 `현재 >= 만료`면 만료로 본다.
/// 관리 DB에는 `[시작, 다음 날 00:00)` 으로 저장한다.
public enum RentalDeskLegacy {
    public static let formatVersion = 1
    public static let product = "RentalDesk"
    public static let edition = "standard"
    public static let defaultUpdatesThrough = "1.0"

    public struct Payload: Equatable, Sendable {
        public var licenseId: String
        public var customerLabel: String
        public var machineCode: String
        public var issuedAtUTC: String
        public var expiresAtUTC: String?
        public var updatesThrough: String

        public init(licenseId: String, customerLabel: String, machineCode: String, issuedAtUTC: String,
                    expiresAtUTC: String?, updatesThrough: String) {
            self.licenseId = licenseId
            self.customerLabel = customerLabel
            self.machineCode = machineCode
            self.issuedAtUTC = issuedAtUTC
            self.expiresAtUTC = expiresAtUTC
            self.updatesThrough = updatesThrough
        }

        /// licensing.py issue_license와 같은 키 순서
        public var json: JSONValue {
            .object(JSONObject([
                ("format_version", .number(JSONNumber(RentalDeskLegacy.formatVersion))),
                ("license_id", .string(licenseId)),
                ("product", .string(RentalDeskLegacy.product)),
                ("edition", .string(RentalDeskLegacy.edition)),
                ("customer_label", .string(customerLabel)),
                ("machine_code", .string(machineCode)),
                ("issued_at_utc", .string(issuedAtUTC)),
                ("expires_at_utc", .str(expiresAtUTC)),
                ("updates_through", .string(updatesThrough)),
            ]))
        }
    }

    public static func signingMessage(payload: JSONValue) throws -> Data {
        try JSONWriter.canonicalData(payload)
    }

    public static func renderFile(payload: JSONValue, signature: Data) -> Data {
        let doc = JSONValue.object(JSONObject([
            ("license", payload),
            ("signature", .string(signature.base64EncodedString())),
        ]))
        return Data(JSONWriter.pretty(doc).utf8)
    }

    /// 관리 기준 만료(미포함, 다음 날 00:00) → 파일 만료(마지막 사용일 23:59:59)
    public static func fileExpiry(fromManagement end: Date) -> Date {
        LicenseTime.truncated(end).addingTimeInterval(-1)
    }

    /// 파일 만료 → 관리 기준 만료. 서울 23:59:59이면 다음 날 00:00, 아니면 그 시각 그대로(앱 판정과 같음).
    public static func managementExpiry(fromFile exp: Date) -> Date {
        let seoulSeconds = (LicenseTime.epochSeconds(exp) + LicenseTime.seoulOffsetSeconds) % 86_400
        return seoulSeconds == 86_399 ? exp.addingTimeInterval(1) : exp
    }
}

public struct RentalDeskLegacyGenerator: LicenseGenerator {
    public let id = GeneratorID.rentaldeskLegacy
    public let version = "1.0.0"
    public let capabilities = GeneratorCapabilities(perpetual: true, term: true, futureStart: false, scheme: .rentaldeskMachineV0)

    public init() {}

    public func validate(_ r: LicenseRequest, now: Date) -> [ValidationIssue] {
        var issues = commonIssues(r, now: now)
        let label = (r.licensee ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if label.isEmpty {
            issues.append(.init(.licensee, "RentalDesk 이전 형식은 고객 표시명(상호 등)이 필요합니다."))
        } else if TextRules.length(label) > 100 {
            issues.append(.init(.licensee, "고객 표시명은 100자 이하여야 합니다."))
        }
        if let mv = r.maxVersion, TextRules.parseSeries(mv) == nil {
            issues.append(.init(.maxVersion, "업데이트 허용 버전은 '주.부' 형식입니다. 예) 1.0"))
        }
        if let exp = r.expiresAt, RentalDeskLegacy.fileExpiry(fromManagement: exp) <= LicenseTime.truncated(r.issuedAt) {
            issues.append(.init(.expiry, "만료 시각이 발급 시각보다 늦어야 합니다."))
        }
        if !TextRules.isLowerUUID(r.licenseId) { issues.append(.init(.general, "라이선스 ID 형식 오류")) }
        return issues
    }

    public func makePayload(_ r: LicenseRequest) -> RentalDeskLegacy.Payload {
        RentalDeskLegacy.Payload(
            licenseId: r.licenseId,
            customerLabel: (r.licensee ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            machineCode: PcScheme.rentaldeskMachineV0.normalize(r.pcNormalized),
            issuedAtUTC: LicenseTime.utcString(r.issuedAt),
            expiresAtUTC: r.expiresAt.map { LicenseTime.utcString(RentalDeskLegacy.fileExpiry(fromManagement: $0)) },
            updatesThrough: r.maxVersion ?? RentalDeskLegacy.defaultUpdatesThrough)
    }

    public func generate(_ r: LicenseRequest, signing: SigningMaterial, now: Date) throws -> GeneratedLicense {
        let issues = validate(r, now: now)
        guard issues.isEmpty else { throw GenerationError(issues) }
        let payload = makePayload(r)
        let message = try RentalDeskLegacy.signingMessage(payload: payload.json)
        let signature = try signing.privateKey.signature(for: message)
        let file = RentalDeskLegacy.renderFile(payload: payload.json, signature: signature)
        return GeneratedLicense(
            generatorID: id, generatorVersion: version, fileBytes: file,
            fileName: "RentalDesk_license_\(PcScheme.rentaldeskMachineV0.display(normalized: payload.machineCode)).json",
            licenseIdInFile: payload.licenseId, keyId: nil, signedMessage: message,
            // 미래 시작 불가: 관리 기준 시작 = 발급 시각
            startsAt: LicenseTime.truncated(r.issuedAt), expiresAt: r.expiresAt.map(LicenseTime.truncated),
            fileConditions: [
                "format": "rentaldesk legacy (format_version 1)",
                "product": RentalDeskLegacy.product,
                "edition": RentalDeskLegacy.edition,
                "customer_label": payload.customerLabel,
                "machine_code": payload.machineCode,
                "issued_at_utc": payload.issuedAtUTC,
                "expires_at_utc": payload.expiresAtUTC ?? "null",
                "updates_through": payload.updatesThrough,
            ])
    }

    public func inspect(fileBytes: Data, publicKeys: [PublicKeyRef]) -> InspectedLicense? {
        guard let raw = try? JSONParser.parse(fileBytes), case .object(let doc) = raw,
              doc["format"] == nil, doc["license"] != nil else { return nil }
        var r = InspectedLicense(generatorID: id, check: .format, pcScheme: .rentaldeskMachineV0)
        // licensing.py verify_license: payload dict, Base64(엄격), format_version == 1
        guard case .object(let p)? = doc["license"], let sigText = doc["signature"]?.stringValue,
              let sig = Data(base64Encoded: sigText), p["format_version"]?.numberValue?.doubleValue == 1 else { return r }
        r.licenseId = p["license_id"]?.stringValue
        r.pcNumber = p["machine_code"]?.stringValue.map { PcScheme.rentaldeskMachineV0.normalize($0) }
        r.licensee = p["customer_label"]?.stringValue
        r.edition = p["edition"]?.stringValue
        r.productCode = p["product"]?.stringValue
        r.maxVersion = p["updates_through"]?.stringValue ?? (p["updates_through"] == nil ? RentalDeskLegacy.defaultUpdatesThrough : nil)
        let issued = p["issued_at_utc"]?.stringValue.flatMap(LicenseTime.parseUTC)
        r.issuedAt = issued
        r.startsAt = issued
        let expRaw = p["expires_at_utc"]?.stringValue
        if let e = expRaw.flatMap(LicenseTime.parseUTC) {
            r.expiresAt = RentalDeskLegacy.managementExpiry(fromFile: e)
        }
        r.isPerpetual = expRaw == nil
        r.signedMessage = try? RentalDeskLegacy.signingMessage(payload: .object(p))
        r.fileConditions = [
            "format": "rentaldesk legacy",
            "customer_label": r.licensee ?? "",
            "machine_code": r.pcNumber ?? "",
            "issued_at_utc": p["issued_at_utc"]?.stringValue ?? "",
            "expires_at_utc": expRaw ?? "null",
            "updates_through": r.maxVersion ?? "",
        ]

        let keys = publicKeys.compactMap { ref in Ed25519Keys.publicKey(raw: ref.raw).map { (ref.keyId, $0) } }
        guard !keys.isEmpty else {
            r.check = .unknownKey
            return r
        }
        guard let message = r.signedMessage,
              let match = keys.first(where: { $0.1.isValidSignature(sig, for: message) }) else {
            r.check = .badSignature
            return r
        }
        r.keyId = match.0
        // _parse_info와 같은 내용 검사
        let stringFields = ["license_id", "product", "edition", "customer_label", "machine_code", "issued_at_utc"]
        let fieldsOK = stringFields.allSatisfy { p[$0]?.stringValue != nil }
        let expiresOK = p["expires_at_utc"] == nil || p["expires_at_utc"]?.isNull == true || r.expiresAt != nil
        let seriesOK = r.maxVersion.map { TextRules.parseSeries($0) != nil } ?? false
        guard fieldsOK, expiresOK, seriesOK, issued != nil, r.productCode == RentalDeskLegacy.product else {
            r.check = .format
            return r
        }
        r.check = .verified
        return r
    }
}
