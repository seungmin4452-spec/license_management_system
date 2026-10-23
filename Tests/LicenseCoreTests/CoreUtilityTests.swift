import CryptoKit
import Foundation
import XCTest
@testable import LicenseCore

final class CoreUtilityTests: XCTestCase {
    func testUTCRoundTripAndStrictParse() {
        let d = Fixtures.utc("2026-10-23T05:00:00Z")
        XCTAssertEqual(LicenseTime.utcString(d), "2026-10-23T05:00:00Z")
        XCTAssertEqual(LicenseTime.utcMillisString(d.addingTimeInterval(0.123)), "2026-10-23T05:00:00.123Z")
        XCTAssertNil(LicenseTime.parseUTC("2026-02-30T00:00:00Z"))
        XCTAssertNil(LicenseTime.parseUTC("0000-01-01T00:00:00Z"))
        XCTAssertNil(LicenseTime.parseUTC("2026-10-23T05:00:00.000Z"))
        XCTAssertNil(LicenseTime.parseUTC("2026-10-23T24:00:00Z"))
        XCTAssertNotNil(LicenseTime.parseUTC("2024-02-29T00:00:00Z"))
        XCTAssertEqual(LicenseTime.parseUTC("0001-01-01T00:00:00Z").map(LicenseTime.utcString), "0001-01-01T00:00:00Z")
        XCTAssertEqual(LicenseTime.parseUTCMillis("2026-10-23T05:00:00.500Z"), d.addingTimeInterval(0.5))
    }

    func testSeoulDayBoundaries() {
        // 2026-11-24까지 사용 → 2026-11-24T15:00:00Z 만료(규격 예시)
        let last = CivilDate(string: "2026-11-24")!
        XCTAssertEqual(LicenseTime.utcString(LicenseTime.endExclusive(lastDay: last)), "2026-11-24T15:00:00Z")
        XCTAssertEqual(LicenseTime.lastUseDay(expiresAt: LicenseTime.endExclusive(lastDay: last)), last)
        // 서울 00:00 = 전날 15:00Z
        XCTAssertEqual(LicenseTime.utcString(LicenseTime.seoulMidnight(CivilDate(string: "2026-10-23")!)), "2026-10-22T15:00:00Z")
        XCTAssertEqual(LicenseTime.seoulDate(of: Fixtures.utc("2026-10-22T15:00:00Z")), CivilDate(string: "2026-10-23"))
        XCTAssertEqual(LicenseTime.seoulDate(of: Fixtures.utc("2026-10-22T14:59:59Z")), CivilDate(string: "2026-10-22"))
        XCTAssertEqual(LicenseTime.seoulDisplay(Fixtures.utc("2026-10-22T15:00:00Z")), "2026-10-23 00:00")
    }

    func testAddMonthsClampsToMonthEnd() {
        XCTAssertEqual(CivilDate(string: "2026-01-31")!.adding(months: 1), CivilDate(string: "2026-02-28"))
        XCTAssertEqual(CivilDate(string: "2028-01-31")!.adding(months: 1), CivilDate(string: "2028-02-29"))
        XCTAssertEqual(CivilDate(string: "2026-10-23")!.adding(months: 1), CivilDate(string: "2026-11-23"))
        XCTAssertEqual(CivilDate(string: "2026-12-15")!.adding(months: 2), CivilDate(string: "2027-02-15"))
        XCTAssertEqual(CivilDate(string: "2026-03-31")!.adding(months: 12), CivilDate(string: "2027-03-31"))
    }

    func testPcSchemes() {
        XCTAssertEqual(PcScheme.suggest(for: "7io36-4gq6p-gkv25-yx5md-rqls4"), .lmsPcV1)
        XCTAssertEqual(PcScheme.suggest(for: "ABCD-2EFG-H3IJ-KL4M-NOP5"), .rentaldeskMachineV0)
        XCTAssertEqual(PcScheme.suggest(for: "VRN-7KQ2-M9XA-3PDF"), .reviewcutInstallId)
        XCTAssertEqual(PcScheme.suggest(for: "00123-abc"), .manual)
        // 정규화 없는 체계: 앞뒤 공백만 제거, 앞자리 0·대소문자·하이픈 보존
        XCTAssertEqual(PcScheme.manual.normalize("  00123-abc \n"), "00123-abc")
        XCTAssertEqual(PcScheme.reviewcutInstallId.normalize(" VRN-7KQ2-M9XA-3PDF "), "VRN-7KQ2-M9XA-3PDF")
        XCTAssertEqual(PcScheme.rentaldeskMachineV0.normalize("abcd 2efg-h3ij-kl4m-nop5"), "ABCD2EFGH3IJKL4MNOP5")
        XCTAssertEqual(PcScheme.rentaldeskMachineV0.display(normalized: "ABCD2EFGH3IJKL4MNOP5"), "ABCD-2EFG-H3IJ-KL4M-NOP5")
        XCTAssertFalse(PcScheme.lmsPcV1.isValid(normalized: "ABCDEFGHIJKLMNOPQRSTUVWX1")) // 1은 Base32 아님
    }

    func testCanonicalJSONEscapes() throws {
        let v = JSONValue.object(JSONObject([
            ("b", .string("a/b \"q\" \\ \u{1} \u{7F} 한글 😀 \t\n\r\u{8}\u{C}")),
            ("a", .null),
            ("c", .object(JSONObject([("z", .number(JSONNumber(1))), ("y", .bool(true))]))),
        ]))
        XCTAssertEqual(try JSONWriter.canonical(v),
                       "{\"a\":null,\"b\":\"a/b \\\"q\\\" \\\\ \\u0001 \u{7F} 한글 😀 \\t\\n\\r\\b\\f\",\"c\":{\"y\":true,\"z\":1}}")
        XCTAssertThrowsError(try JSONWriter.canonical(.number(JSONNumber(raw: "1.5"))))
        // 파서: 이스케이프된 슬래시와 서로게이트 쌍
        XCTAssertEqual(try JSONParser.parse("\"a\\/b\\ud83d\\ude00\""), .string("a/b😀"))
        XCTAssertThrowsError(try JSONParser.parse("\"\\ud83d\""))
        XCTAssertThrowsError(try JSONParser.parse("{\"a\":1,}"))
    }

    func testStrictBase64() {
        XCTAssertNotNil(TextRules.strictBase64("AAAA"))
        XCTAssertNil(TextRules.strictBase64("not base64!!"))
        XCTAssertNotNil(TextRules.strictBase64("AAA="))
        XCTAssertNil(TextRules.strictBase64("AAB="))   // 비정규(쓰지 않는 하위 비트가 1) → 재인코딩 불일치
    }

    func testKeyImportFormats() throws {
        let seed = Data(SHA256.hash(data: Data("seed".utf8)))
        let key = try Ed25519Keys.privateKey(seed: seed)
        let pem = Ed25519Keys.pkcs8PEM(seed: seed)
        XCTAssertEqual(try Ed25519Keys.seed(fromFileContents: Data(pem.utf8)), seed)
        let json = "{\n  \"type\": \"ed25519\",\n  \"private_key_hex\": \"\(TextRules.hex(seed))\"\n}"
        XCTAssertEqual(try Ed25519Keys.seed(fromFileContents: Data(json.utf8)), seed)
        XCTAssertEqual(try Ed25519Keys.seed(fromFileContents: Data(TextRules.hex(seed).utf8)), seed)
        // 공개키 표기
        let raw = key.publicKey.rawRepresentation
        XCTAssertEqual(Ed25519Keys.publicKeyRaw(fromText: Ed25519Keys.spkiPEM(publicKeyRaw: raw)), raw)
        XCTAssertEqual(Ed25519Keys.publicKeyRaw(fromText: TextRules.hex(raw)), raw)
        // 다른 공개키와 대조 → 거부
        XCTAssertThrowsError(try Ed25519Keys.checkMatches(seed: seed, expectedPublicKeyRaw: Data(repeating: 1, count: 32)))
        XCTAssertNoThrow(try Ed25519Keys.checkMatches(seed: seed, expectedPublicKeyRaw: raw))
    }

    func testKnownCustomerAppKeys() {
        // ReviewCut SPKI PEM → hex 변환이 되어야 한다
        XCTAssertEqual(KnownCustomerAppKeys.reviewCut.publicKeyHex.count, 64)
        XCTAssertEqual(KnownCustomerAppKeys.rentalDesk.publicKeyHex, "45eeeecbf1cc40fe0233592fb6b1f4f452af64923f29876659a419e68af07934")
    }
}
