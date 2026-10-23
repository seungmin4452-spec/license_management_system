import CryptoKit
import Foundation

public enum KeyImportError: Error, Equatable, LocalizedError {
    case unreadable
    case notEd25519
    case badSeedLength
    case publicKeyMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .unreadable: return "비밀키 파일 형식을 읽을 수 없습니다. PKCS#8 PEM, JSON(private_key_hex), 64자리 hex 중 하나여야 합니다."
        case .notEd25519: return "Ed25519 비밀키가 아닙니다."
        case .badSeedLength: return "비밀키 길이가 올바르지 않습니다(32바이트 seed 필요)."
        case .publicKeyMismatch:
            return "가져온 비밀키의 공개키가 고객 앱에 들어 있는 공개키와 다릅니다. 다른 키 파일입니다. 이 키로 발급하면 고객 앱이 라이선스를 인정하지 않으므로 거부했습니다."
        }
    }
}

/// Ed25519 키 표기 변환. 비밀키(seed)는 이 타입 밖으로 문자열로 나가지 않게 주의한다.
public enum Ed25519Keys {
    /// PKCS#8 v1 Ed25519 비밀키 DER 머리부(뒤에 32바이트 seed)
    public static let pkcs8Prefix = Data([0x30, 0x2E, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20])
    /// SPKI Ed25519 공개키 DER 머리부(뒤에 32바이트 공개키)
    public static let spkiPrefix = Data([0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00])
    private static let ed25519OID = Data([0x06, 0x03, 0x2B, 0x65, 0x70])

    public static func newPrivateKey() -> Curve25519.Signing.PrivateKey {
        Curve25519.Signing.PrivateKey()
    }

    public static func privateKey(seed: Data) throws -> Curve25519.Signing.PrivateKey {
        guard seed.count == 32 else { throw KeyImportError.badSeedLength }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }

    public static func publicKey(raw: Data) -> Curve25519.Signing.PublicKey? {
        guard raw.count == 32 else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    public static func publicKeyHex(_ key: Curve25519.Signing.PublicKey) -> String {
        TextRules.hex(key.rawRepresentation)
    }

    public static func spkiPEM(publicKeyRaw raw: Data) -> String {
        let der = spkiPrefix + raw
        return "-----BEGIN PUBLIC KEY-----\n\(der.base64EncodedString())\n-----END PUBLIC KEY-----\n"
    }

    public static func pkcs8PEM(seed: Data) -> String {
        let der = pkcs8Prefix + seed
        return "-----BEGIN PRIVATE KEY-----\n\(der.base64EncodedString())\n-----END PRIVATE KEY-----\n"
    }

    /// PEM 본문(Base64) → DER
    public static func derFromPEM(_ text: String, label: String) -> Data? {
        let begin = "-----BEGIN \(label)-----"
        let end = "-----END \(label)-----"
        guard let r1 = text.range(of: begin), let r2 = text.range(of: end, range: r1.upperBound..<text.endIndex) else {
            return nil
        }
        let body = text[r1.upperBound..<r2.lowerBound].filter { !$0.isWhitespace }
        return Data(base64Encoded: String(body))
    }

    /// 공개키 표기(hex 64자리, SPKI PEM, SPKI DER Base64) → 32바이트
    public static func publicKeyRaw(fromText text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hex = TextRules.dataFromHex(trimmed), hex.count == 32 { return hex }
        if let der = derFromPEM(trimmed, label: "PUBLIC KEY") { return spkiRaw(der) }
        if let der = Data(base64Encoded: trimmed) { return spkiRaw(der) }
        return nil
    }

    private static func spkiRaw(_ der: Data) -> Data? {
        guard der.count == 44, der.prefix(12) == spkiPrefix else { return nil }
        return Data(der.suffix(32))
    }

    /// PKCS#8 DER에서 Ed25519 seed 추출. OID 확인 후 `04 22 04 20` 다음 32바이트(없으면 마지막 32바이트).
    public static func seed(fromPKCS8 der: Data) throws -> Data {
        let bytes = [UInt8](der)
        guard let oidRange = Data(bytes).range(of: ed25519OID) else { throw KeyImportError.notEd25519 }
        let marker = Data([0x04, 0x22, 0x04, 0x20])
        if let r = Data(bytes).range(of: marker, in: oidRange.upperBound..<bytes.count), r.upperBound + 32 <= bytes.count {
            return Data(bytes[r.upperBound..<(r.upperBound + 32)])
        }
        guard bytes.count >= 48 else { throw KeyImportError.badSeedLength }
        return Data(bytes.suffix(32))
    }

    /// 비밀키 파일 내용 → seed. 지원: PKCS#8 PEM, RentalDesk JSON(`private_key_hex`), seed hex 64자리.
    public static func seed(fromFileContents data: Data) throws -> Data {
        guard let text = String(data: data, encoding: .utf8) else { throw KeyImportError.unreadable }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("-----BEGIN") {
            guard let der = derFromPEM(trimmed, label: "PRIVATE KEY") else { throw KeyImportError.unreadable }
            return try seed(fromPKCS8: der)
        }
        if trimmed.hasPrefix("{") {
            guard case .object(let obj)? = try? JSONParser.parse(trimmed),
                  let hex = obj["private_key_hex"]?.stringValue,
                  let seed = TextRules.dataFromHex(hex) else { throw KeyImportError.unreadable }
            guard seed.count == 32 else { throw KeyImportError.badSeedLength }
            return seed
        }
        if let seed = TextRules.dataFromHex(trimmed) {
            guard seed.count == 32 else { throw KeyImportError.badSeedLength }
            return seed
        }
        throw KeyImportError.unreadable
    }

    /// 가져온 seed의 공개키가 기대한 공개키와 같은지 확인한다. 다르면 거부.
    public static func checkMatches(seed: Data, expectedPublicKeyRaw expected: Data) throws -> Curve25519.Signing.PrivateKey {
        let key = try privateKey(seed: seed)
        let actual = key.publicKey.rawRepresentation
        guard actual == expected else {
            throw KeyImportError.publicKeyMismatch(expected: TextRules.hex(expected), actual: TextRules.hex(actual))
        }
        return key
    }
}

/// 이미 판매한 고객 앱에 들어 있는 공개키(비밀 아님). 기존 키를 가져올 때 대조한다.
public enum KnownCustomerAppKeys {
    public struct Entry: Sendable {
        public let productName: String
        public let v1ProductCode: String
        public let keyId: String
        public let publicKeyHex: String
        public let hint: String
    }

    public static let reviewCut = Entry(
        productName: "ReviewCut",
        v1ProductCode: "REVIEWCUT",
        keyId: "prod-2026",
        // SPKI PEM MCowBQYDK2VwAyEAfJXxYd3VijTr1PC3AfVS6Q1J3/nwpv4s2UVEIly2x7k=
        publicKeyHex: TextRules.hex(Ed25519Keys.publicKeyRaw(fromText: "MCowBQYDK2VwAyEAfJXxYd3VijTr1PC3AfVS6Q1J3/nwpv4s2UVEIly2x7k=")!),
        hint: "Windows PC의 %USERPROFILE%\\ReviewCut-license-keys\\prod-2026.private.pem (PKCS#8 PEM)"
    )

    public static let rentalDesk = Entry(
        productName: "RentalDesk",
        v1ProductCode: "RENTALDESK",
        keyId: "rentaldesk-2026",
        publicKeyHex: "45eeeecbf1cc40fe0233592fb6b1f4f452af64923f29876659a419e68af07934",
        hint: "~/RentDeskSellerKeys/signing_key.json 의 private_key_hex"
    )

    public static let all = [reviewCut, rentalDesk]

    public static func entry(v1ProductCode: String, keyId: String) -> Entry? {
        all.first { $0.v1ProductCode == v1ProductCode && $0.keyId == keyId }
    }
}
