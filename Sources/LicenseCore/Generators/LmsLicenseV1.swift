import CryptoKit
import Foundation

/// 공통 형식 v1 (`lms-license` v1). 기준: `docs/license-format-v1.md`. 이 문서와 다르게 구현하지 않는다.
public enum LmsLicenseV1 {
    public static let format = "lms-license"
    public static let signPrefix = "lms-license-v1:"
    public static let maxFileBytes = 16 * 1024

    /// 검증 결과 코드(규격 5절 순서)
    public enum Code: String, CaseIterable, Sendable {
        case valid
        case format
        case unknownKey = "unknown_key"
        case badSignature = "bad_signature"
        case product
        case pcId = "pc_id"
        case notYetValid = "not_yet_valid"
        case expired
        case version
    }

    public static let envelopeFields: Set<String> = ["format", "version", "key_id", "payload", "signature"]
    /// payload 필드(파일에 쓰는 순서)
    public static let payloadFieldOrder = [
        "license_id", "product_code", "pc_id", "issued_at", "starts_at", "expires_at",
        "edition", "max_version", "licensee", "options",
    ]
    public static let payloadFields = Set(payloadFieldOrder)

    public struct Payload: Equatable, Sendable {
        public var licenseId: String
        public var productCode: String
        public var pcId: String
        public var issuedAt: String
        public var startsAt: String
        public var expiresAt: String?
        public var edition: String
        public var maxVersion: String?
        public var licensee: String?
        public var options: [(String, String)]

        public init(licenseId: String, productCode: String, pcId: String, issuedAt: String, startsAt: String,
                    expiresAt: String?, edition: String, maxVersion: String?, licensee: String?,
                    options: [(String, String)]) {
            self.licenseId = licenseId
            self.productCode = productCode
            self.pcId = pcId
            self.issuedAt = issuedAt
            self.startsAt = startsAt
            self.expiresAt = expiresAt
            self.edition = edition
            self.maxVersion = maxVersion
            self.licensee = licensee
            self.options = options
        }

        public static func == (a: Payload, b: Payload) -> Bool { a.json == b.json }

        /// 파일에 쓰는 순서의 JSON 객체
        public var json: JSONValue {
            var opts = JSONObject()
            for (k, v) in options.sorted(by: { JSONWriter.codePointLess($0.0, $1.0) }) { opts[k] = .string(v) }
            return .object(JSONObject([
                ("license_id", .string(licenseId)),
                ("product_code", .string(productCode)),
                ("pc_id", .string(pcId)),
                ("issued_at", .string(issuedAt)),
                ("starts_at", .string(startsAt)),
                ("expires_at", .str(expiresAt)),
                ("edition", .string(edition)),
                ("max_version", .str(maxVersion)),
                ("licensee", .str(licensee)),
                ("options", .object(opts)),
            ]))
        }

        /// 형식 검사를 통과한 JSON에서 읽는다
        init?(validated v: JSONValue) {
            guard case .object(let o) = v, case .object(let opts)? = o["options"] else { return nil }
            guard let licenseId = o["license_id"]?.stringValue, let productCode = o["product_code"]?.stringValue,
                  let pcId = o["pc_id"]?.stringValue, let issuedAt = o["issued_at"]?.stringValue,
                  let startsAt = o["starts_at"]?.stringValue, let edition = o["edition"]?.stringValue else { return nil }
            self.init(licenseId: licenseId, productCode: productCode, pcId: pcId, issuedAt: issuedAt,
                      startsAt: startsAt, expiresAt: o["expires_at"]?.stringValue, edition: edition,
                      maxVersion: o["max_version"]?.stringValue, licensee: o["licensee"]?.stringValue,
                      options: opts.entries.compactMap { e in e.value.stringValue.map { (e.key, $0) } })
        }
    }

    // MARK: - 서명 대상

    /// `UTF-8("lms-license-v1:") ++ UTF-8(canonical_json(payload))`
    public static func signingMessage(payload: JSONValue) throws -> Data {
        Data((signPrefix + (try JSONWriter.canonical(payload))).utf8)
    }

    // MARK: - 형식 검사

    private static func validText(_ v: JSONValue?, max: Int, min: Int = 0) -> Bool {
        guard let s = v?.stringValue, !TextRules.hasControl(s) else { return false }
        let n = TextRules.length(s)
        return n >= min && n <= max
    }

    private static func validTime(_ v: JSONValue?) -> Bool {
        guard let s = v?.stringValue else { return false }
        return LicenseTime.parseUTC(s) != nil
    }

    /// payload가 규격을 어기면 이유(개발자용), 맞으면 nil
    public static func payloadProblem(_ value: JSONValue?) -> String? {
        guard case .object(let x)? = value, x.hasExactly(payloadFields) else { return "필드 구성이 다릅니다" }
        let checks: [(String, Bool)] = [
            ("license_id", x["license_id"]?.stringValue.map(TextRules.isLowerUUID) ?? false),
            ("product_code", x["product_code"]?.stringValue.map(TextRules.isV1ProductCode) ?? false),
            ("pc_id", x["pc_id"]?.stringValue.map { TextRules.isBase32($0, length: 25) } ?? false),
            ("issued_at", validTime(x["issued_at"])),
            ("starts_at", validTime(x["starts_at"])),
            ("expires_at", x["expires_at"]?.isNull == true || validTime(x["expires_at"])),
            ("edition", x["edition"]?.stringValue.map(TextRules.isEdition) ?? false),
            ("max_version", x["max_version"]?.isNull == true
                || (x["max_version"]?.stringValue.map { TextRules.parseSeries($0) != nil } ?? false)),
            ("licensee", x["licensee"]?.isNull == true
                || (validText(x["licensee"], max: 100, min: 1) && !TextRules.hasEdgeSpace(x["licensee"]?.stringValue ?? ""))),
            ("options", {
                guard case .object(let opts)? = x["options"], opts.count <= 20 else { return false }
                return opts.entries.allSatisfy { TextRules.isOptionKey($0.key) && validText($0.value, max: 200) }
            }()),
        ]
        for (name, ok) in checks where !ok { return "\(name) 형식 오류" }
        if let exp = x["expires_at"]?.stringValue, let e = LicenseTime.parseUTC(exp),
           let s = x["starts_at"]?.stringValue.flatMap(LicenseTime.parseUTC), e <= s {
            return "expires_at이 starts_at보다 늦어야 합니다"
        }
        return nil
    }

    // MARK: - 검증

    /// 서명까지 검사(1~3단계). 성공하면 payload를 돌려준다.
    public static func checkSignature(document raw: JSONValue, publicKeys: [String: Curve25519.Signing.PublicKey])
        -> (code: Code, payload: Payload?, keyId: String?) {
        guard case .object(let doc) = raw, doc.hasExactly(envelopeFields) else { return (.format, nil, nil) }
        guard doc["format"]?.stringValue == format,
              let ver = doc["version"]?.numberValue, ver.doubleValue == 1 else { return (.format, nil, nil) }
        guard let keyId = doc["key_id"]?.stringValue, TextRules.isKeyId(keyId) else { return (.format, nil, nil) }
        guard let sigText = doc["signature"]?.stringValue, let sig = TextRules.strictBase64(sigText), sig.count == 64 else {
            return (.format, nil, keyId)
        }
        guard payloadProblem(doc["payload"]) == nil, let payloadJSON = doc["payload"],
              let payload = Payload(validated: payloadJSON) else { return (.format, nil, keyId) }
        guard let key = publicKeys[keyId] else { return (.unknownKey, payload, keyId) }
        guard let message = try? signingMessage(payload: payloadJSON),
              key.isValidSignature(sig, for: message) else { return (.badSignature, payload, keyId) }
        return (.valid, payload, keyId)
    }

    private static func covered(appVersion: String, maxVersion: String) -> Bool {
        guard let a = TextRules.parseAppVersion(appVersion), let s = TextRules.parseSeries(maxVersion) else { return false }
        return a.0 < s.0 || (a.0 == s.0 && a.1 <= s.1)
    }

    /// 고객 앱과 같은 전체 검증(규격 5절). 테스트 벡터 확인용.
    public static func verify(document raw: JSONValue, publicKeys: [String: Curve25519.Signing.PublicKey],
                              productCode: String, pcId: String?, now: Date, appVersion: String) -> Code {
        let (code, payload, _) = checkSignature(document: raw, publicKeys: publicKeys)
        guard code == .valid, let p = payload else { return code }
        if p.productCode != productCode { return .product }
        guard let pc = pcId, p.pcId == PcScheme.lmsPcV1.normalize(pc) else { return .pcId }
        let t = LicenseTime.epochSeconds(now)
        if let s = LicenseTime.parseUTC(p.startsAt), t < LicenseTime.epochSeconds(s) { return .notYetValid }
        if let e = p.expiresAt.flatMap(LicenseTime.parseUTC), t >= LicenseTime.epochSeconds(e) { return .expired }
        if let mv = p.maxVersion, !covered(appVersion: appVersion, maxVersion: mv) { return .version }
        return .valid
    }

    public static func verify(fileBytes: Data, publicKeys: [String: Curve25519.Signing.PublicKey],
                              productCode: String, pcId: String?, now: Date, appVersion: String) -> Code {
        guard fileBytes.count <= maxFileBytes, let raw = try? JSONParser.parse(fileBytes) else { return .format }
        return verify(document: raw, publicKeys: publicKeys, productCode: productCode, pcId: pcId, now: now,
                      appVersion: appVersion)
    }

    /// 파일 저장 형식: 들여쓰기 2칸 + 끝 줄바꿈(기존 발급 도구와 같음)
    public static func renderFile(keyId: String, payload: Payload, signature: Data) -> Data {
        let doc = JSONValue.object(JSONObject([
            ("format", .string(format)),
            ("version", .number(JSONNumber(1))),
            ("key_id", .string(keyId)),
            ("payload", payload.json),
            ("signature", .string(signature.base64EncodedString())),
        ]))
        return Data((JSONWriter.pretty(doc) + "\n").utf8)
    }
}

/// 공통 형식 v1 생성기 — 모든 공통 형식 제품(ReviewCut·RentalDesk 새 버전, 이후 신제품)
public struct LmsLicenseV1Generator: LicenseGenerator {
    public let id = GeneratorID.lmsLicenseV1
    public let version = "1.0.0"
    public let capabilities = GeneratorCapabilities(perpetual: true, term: true, futureStart: true, scheme: .lmsPcV1)

    public init() {}

    public func validate(_ r: LicenseRequest, now: Date) -> [ValidationIssue] {
        var issues = commonIssues(r, now: now)
        if !TextRules.isV1ProductCode(r.productCode) {
            issues.append(.init(.productCode, "공통 형식 제품 코드가 올바르지 않습니다(영문 대문자로 시작, 대문자·숫자·_ 2~32자)."))
        }
        if !TextRules.isEdition(r.edition) {
            issues.append(.init(.edition, "에디션은 영문 소문자로 시작하는 1~32자(소문자·숫자·_·-)입니다. 예) full, standard"))
        }
        if let mv = r.maxVersion, TextRules.parseSeries(mv) == nil {
            issues.append(.init(.maxVersion, "사용 가능 최고 버전은 '주.부' 형식입니다. 예) 1.0"))
        }
        if let l = r.licensee {
            let s = TextRules.stripEdge(l)
            if TextRules.length(s) > 100 { issues.append(.init(.licensee, "고객 표시명은 100자 이하여야 합니다.")) }
            if TextRules.hasControl(s) { issues.append(.init(.licensee, "고객 표시명에 줄바꿈·제어 문자를 넣을 수 없습니다.")) }
        }
        if r.options.count > 20 { issues.append(.init(.options, "제품별 옵션은 20개까지입니다.")) }
        for (k, v) in r.options {
            if !TextRules.isOptionKey(k) { issues.append(.init(.options, "옵션 이름 '\(k)'이(가) 올바르지 않습니다(영문 소문자로 시작, 소문자·숫자·_).")) }
            if TextRules.length(v) > 200 || TextRules.hasControl(v) { issues.append(.init(.options, "옵션 '\(k)' 값은 200자 이하, 제어 문자 없이 입력하세요.")) }
        }
        if !TextRules.isLowerUUID(r.licenseId) { issues.append(.init(.general, "라이선스 ID 형식 오류")) }
        return issues
    }

    public func makePayload(_ r: LicenseRequest) -> LmsLicenseV1.Payload {
        let licensee = r.licensee.map(TextRules.stripEdge).flatMap { $0.isEmpty ? nil : $0 }
        return LmsLicenseV1.Payload(
            licenseId: r.licenseId,
            productCode: r.productCode,
            pcId: PcScheme.lmsPcV1.normalize(r.pcNormalized),
            issuedAt: LicenseTime.utcString(r.issuedAt),
            startsAt: LicenseTime.utcString(r.startsAt),
            expiresAt: r.expiresAt.map(LicenseTime.utcString),
            edition: r.edition,
            maxVersion: r.maxVersion,
            licensee: licensee,
            options: r.options.map { ($0.key, $0.value) }
        )
    }

    public func generate(_ r: LicenseRequest, signing: SigningMaterial, now: Date) throws -> GeneratedLicense {
        var issues = validate(r, now: now)
        if !TextRules.isKeyId(signing.keyId) { issues.append(.init(.key, "서명 키 이름(key_id) 형식이 올바르지 않습니다.")) }
        guard issues.isEmpty else { throw GenerationError(issues) }
        let payload = makePayload(r)
        if let problem = LmsLicenseV1.payloadProblem(payload.json) {
            throw GenerationError([.init(.general, "라이선스 내용이 규격에 맞지 않습니다: \(problem)")])
        }
        let message = try LmsLicenseV1.signingMessage(payload: payload.json)
        let signature = try signing.privateKey.signature(for: message)
        let file = LmsLicenseV1.renderFile(keyId: signing.keyId, payload: payload, signature: signature)
        var conditions: [String: String] = [
            "format": "lms-license v1",
            "key_id": signing.keyId,
            "product_code": payload.productCode,
            "pc_id": payload.pcId,
            "issued_at": payload.issuedAt,
            "starts_at": payload.startsAt,
            "expires_at": payload.expiresAt ?? "null",
            "edition": payload.edition,
            "max_version": payload.maxVersion ?? "null",
            "licensee": payload.licensee ?? "null",
        ]
        for (k, v) in payload.options { conditions["options.\(k)"] = v }
        return GeneratedLicense(
            generatorID: id, generatorVersion: version, fileBytes: file,
            fileName: "\(payload.productCode)-license-\(PcScheme.lmsPcV1.display(normalized: payload.pcId)).json",
            licenseIdInFile: payload.licenseId, keyId: signing.keyId, signedMessage: message,
            startsAt: LicenseTime.truncated(r.startsAt), expiresAt: r.expiresAt.map(LicenseTime.truncated),
            fileConditions: conditions)
    }

    public func inspect(fileBytes: Data, publicKeys: [PublicKeyRef]) -> InspectedLicense? {
        guard let raw = try? JSONParser.parse(fileBytes), case .object(let doc) = raw,
              doc["format"]?.stringValue == LmsLicenseV1.format else { return nil }
        var keys: [String: Curve25519.Signing.PublicKey] = [:]
        for k in publicKeys { if let pk = Ed25519Keys.publicKey(raw: k.raw) { keys[k.keyId] = pk } }
        var result: (code: LmsLicenseV1.Code, payload: LmsLicenseV1.Payload?, keyId: String?) = (.format, nil, nil)
        if fileBytes.count <= LmsLicenseV1.maxFileBytes {
            result = LmsLicenseV1.checkSignature(document: raw, publicKeys: keys)
        }
        let (code, payload, keyId) = result
        let check: SignatureCheck
        switch code {
        case .valid: check = .verified
        case .unknownKey: check = .unknownKey
        case .badSignature: check = .badSignature
        default: check = .format
        }
        var r = InspectedLicense(generatorID: id, check: check, pcScheme: .lmsPcV1)
        r.keyId = keyId
        if let p = payload {
            r.licenseId = p.licenseId
            r.pcNumber = p.pcId
            r.productCode = p.productCode
            r.issuedAt = LicenseTime.parseUTC(p.issuedAt)
            r.startsAt = LicenseTime.parseUTC(p.startsAt)
            r.expiresAt = p.expiresAt.flatMap(LicenseTime.parseUTC)
            r.isPerpetual = p.expiresAt == nil
            r.licensee = p.licensee
            r.edition = p.edition
            r.maxVersion = p.maxVersion
            r.signedMessage = try? LmsLicenseV1.signingMessage(payload: p.json)
            r.fileConditions = [
                "format": "lms-license v1", "key_id": keyId ?? "", "product_code": p.productCode, "pc_id": p.pcId,
                "issued_at": p.issuedAt, "starts_at": p.startsAt, "expires_at": p.expiresAt ?? "null",
                "edition": p.edition, "max_version": p.maxVersion ?? "null", "licensee": p.licensee ?? "null",
            ]
        }
        return r
    }
}
