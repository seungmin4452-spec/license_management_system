import CryptoKit
import Foundation
import XCTest
@testable import LicenseCore

/// 이전 형식 호환 테스트.
/// `docs/legacy-fixtures/*.json` 은 각 앱 저장소의 실제 서명·검증 코드로 만들고 확인한 고정 예제다
/// (`tools/gen_legacy_fixtures_reviewcut.mjs`, `tools/gen_legacy_fixtures_rentaldesk.py`).
/// 확인 항목: (1) 같은 payload에서 관리 프로그램이 만드는 서명 대상 바이트가 같다
/// (2) 같은 서명을 넣으면 파일 바이트까지 같다 (3) 관리 프로그램 검사 함수가 예제를 통과시킨다
/// (4) 관리 프로그램이 새로 서명한 파일도 검증을 통과한다.
final class LegacyFormatTests: XCTestCase {
    func loadKey(_ fixture: JSONObject) throws -> (seed: Data, pub: Data, keyId: String?) {
        let key = try XCTUnwrap(fixture["test_key"]?.objectValue)
        let seed = try XCTUnwrap(TextRules.dataFromHex(XCTUnwrap(key["seed_hex"]?.stringValue)))
        let pub = try XCTUnwrap(TextRules.dataFromHex(XCTUnwrap(key["public_key_hex"]?.stringValue)))
        XCTAssertEqual(try Ed25519Keys.privateKey(seed: seed).publicKey.rawRepresentation, pub)
        return (seed, pub, key["key_id"]?.stringValue)
    }

    // MARK: ReviewCut

    func testReviewCutFixtures() throws {
        let fixture = try Fixtures.json("docs/legacy-fixtures/reviewcut-legacy.json")
        let (seed, pub, keyIdOpt) = try loadKey(fixture)
        let keyId = try XCTUnwrap(keyIdOpt)
        let gen = ReviewCutLegacyGenerator()
        let cases = try XCTUnwrap(fixture["cases"]).arrayValue
        XCTAssertEqual(cases.count, 3)
        for c in cases {
            let name = c["name"]?.stringValue ?? "?"
            let fileText = try XCTUnwrap(c["file_text"]?.stringValue)
            let fileBytes = Data(fileText.utf8)
            let parsed = try JSONParser.parse(fileBytes)
            let payloadJSON = try XCTUnwrap(parsed["payload"])

            // (1) 서명 대상 바이트
            let message = try ReviewCutLegacy.signingMessage(payload: payloadJSON)
            XCTAssertEqual(String(decoding: message, as: UTF8.self), c["message_utf8"]?.stringValue, name)

            // (2) 같은 입력으로 만든 payload + 앱이 만든 서명 → 파일 바이트 일치
            let p = try XCTUnwrap(payloadJSON.objectValue)
            let ours = ReviewCutLegacy.Payload(
                licenseId: p["licenseId"]!.stringValue!, installId: p["installId"]!.stringValue!,
                licensee: p["licensee"]?.stringValue, issuedAt: p["issuedAt"]!.stringValue!)
            XCTAssertEqual(try ReviewCutLegacy.signingMessage(payload: ours.json), message, name)
            let sig = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(parsed["signature"]?.stringValue)))
            XCTAssertEqual(String(decoding: ReviewCutLegacy.renderFile(payload: ours.json, signature: sig, keyId: keyId), as: UTF8.self),
                           fileText, "file bytes: \(name)")

            // (3) 검사 함수
            let inspected = try XCTUnwrap(gen.inspect(fileBytes: fileBytes, publicKeys: [PublicKeyRef(keyId: keyId, raw: pub)]))
            XCTAssertEqual(inspected.check, .verified, name)
            XCTAssertEqual(inspected.pcNumber, c["install_id"]?.stringValue)
            XCTAssertTrue(inspected.isPerpetual)
            // 다른 키 → 거부
            let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
            XCTAssertEqual(gen.inspect(fileBytes: fileBytes, publicKeys: [PublicKeyRef(keyId: keyId, raw: other)])?.check, .badSignature)
            XCTAssertEqual(gen.inspect(fileBytes: fileBytes, publicKeys: [PublicKeyRef(keyId: "nope", raw: pub)])?.check, .unknownKey)
        }

        // (4) 새로 서명
        let request = LicenseRequest(
            productCode: "", pcScheme: .reviewcutInstallId, pcRaw: "VRN-7KQ2-M9XA-3PDF", pcNormalized: "VRN-7KQ2-M9XA-3PDF",
            issuedAt: Fixtures.utc("2026-10-23T05:00:00Z"), startsAt: Fixtures.utc("2026-10-23T05:00:00Z"),
            expiresAt: nil, licensee: " OO스튜디오 ", edition: "full", maxVersion: nil,
            licenseId: "0b7f3a52-5d0e-4c1a-9a8e-3f6b2d1c4e5a")
        let out = try gen.generate(request, signing: SigningMaterial(keyId: keyId, privateKey: Ed25519Keys.privateKey(seed: seed)),
                                   now: Fixtures.utc("2026-10-23T05:00:00Z"))
        XCTAssertEqual(out.signedMessageText, cases[0]["message_utf8"]?.stringValue)
        XCTAssertEqual(gen.inspect(fileBytes: out.fileBytes, publicKeys: [PublicKeyRef(keyId: keyId, raw: pub)])?.check, .verified)
    }

    func testReviewCutRejectsTermAndFutureStart() {
        let gen = ReviewCutLegacyGenerator()
        let now = Fixtures.utc("2026-10-23T05:00:00Z")
        var r = LicenseRequest(productCode: "", pcScheme: .reviewcutInstallId, pcRaw: "VRN-7KQ2-M9XA-3PDF",
                               pcNormalized: "VRN-7KQ2-M9XA-3PDF", issuedAt: now, startsAt: now,
                               expiresAt: now.addingTimeInterval(86_400), licensee: nil, edition: "full", maxVersion: nil)
        XCTAssertTrue(gen.validate(r, now: now).contains { $0.field == .period })
        r.expiresAt = nil
        r.startsAt = now.addingTimeInterval(86_400)
        XCTAssertTrue(gen.validate(r, now: now).contains { $0.field == .start })
        r.startsAt = now
        XCTAssertEqual(gen.validate(r, now: now), [])
        // 소문자 설치 ID는 형식 오류(정규화 없음)
        r.pcNormalized = "vrn-7kq2-m9xa-3pdf"
        XCTAssertTrue(gen.validate(r, now: now).contains { $0.field == .pc })
    }

    // MARK: RentalDesk

    func testRentalDeskFixtures() throws {
        let fixture = try Fixtures.json("docs/legacy-fixtures/rentaldesk-legacy.json")
        let (seed, pub, _) = try loadKey(fixture)
        let gen = RentalDeskLegacyGenerator()
        let cases = try XCTUnwrap(fixture["cases"]).arrayValue
        XCTAssertEqual(cases.count, 3)
        for c in cases {
            let name = c["name"]?.stringValue ?? "?"
            let fileText = try XCTUnwrap(c["file_text"]?.stringValue)
            let fileBytes = Data(fileText.utf8)
            let parsed = try JSONParser.parse(fileBytes)
            let payloadJSON = try XCTUnwrap(parsed["license"])
            let message = try RentalDeskLegacy.signingMessage(payload: payloadJSON)
            XCTAssertEqual(String(decoding: message, as: UTF8.self), c["message_utf8"]?.stringValue, name)

            let p = try XCTUnwrap(payloadJSON.objectValue)
            let ours = RentalDeskLegacy.Payload(
                licenseId: p["license_id"]!.stringValue!, customerLabel: p["customer_label"]!.stringValue!,
                machineCode: p["machine_code"]!.stringValue!, issuedAtUTC: p["issued_at_utc"]!.stringValue!,
                expiresAtUTC: p["expires_at_utc"]?.stringValue, updatesThrough: p["updates_through"]!.stringValue!)
            let sig = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(parsed["signature"]?.stringValue)))
            XCTAssertEqual(String(decoding: RentalDeskLegacy.renderFile(payload: ours.json, signature: sig), as: UTF8.self),
                           fileText, "file bytes: \(name)")

            let inspected = try XCTUnwrap(gen.inspect(fileBytes: fileBytes, publicKeys: [PublicKeyRef(keyId: "rentaldesk-2026", raw: pub)]))
            XCTAssertEqual(inspected.check, .verified, name)
            XCTAssertEqual(inspected.pcNumber, c["machine_code"]?.stringValue)
        }

        // 기간제: 파일 23:59:59 ↔ 관리 다음 날 00:00
        let termText = try XCTUnwrap(cases[1]["file_text"]?.stringValue)
        let term = try XCTUnwrap(gen.inspect(fileBytes: Data(termText.utf8), publicKeys: [PublicKeyRef(keyId: "k", raw: pub)]))
        XCTAssertEqual(term.fileConditions["expires_at_utc"], "2026-11-23T14:59:59Z")
        XCTAssertEqual(term.expiresAt, Fixtures.utc("2026-11-23T15:00:00Z"))
        XCTAssertEqual(LicenseTime.lastUseDay(expiresAt: term.expiresAt!), CivilDate(string: "2026-11-23"))

        // 새로 서명: 같은 조건 → 같은 서명 대상 바이트
        let request = LicenseRequest(
            productCode: "", pcScheme: .rentaldeskMachineV0, pcRaw: "ABCD-2EFG-H3IJ-KL4M-NOP5", pcNormalized: "ABCD2EFGH3IJKL4MNOP5",
            issuedAt: Fixtures.utc("2026-10-23T05:00:00Z"), startsAt: Fixtures.utc("2026-10-23T05:00:00Z"),
            expiresAt: LicenseTime.endExclusive(lastDay: CivilDate(string: "2026-11-23")!), licensee: "OO렌탈",
            edition: "standard", maxVersion: "1.0", licenseId: "5a7b9c1d-3e4f-4a5b-9c6d-7e8f9a0b1c2d")
        let out = try gen.generate(request, signing: SigningMaterial(keyId: "rentaldesk-2026", privateKey: Ed25519Keys.privateKey(seed: seed)),
                                   now: Fixtures.utc("2026-10-23T05:00:00Z"))
        XCTAssertEqual(out.signedMessageText, cases[1]["message_utf8"]?.stringValue)
        XCTAssertEqual(out.fileConditions["expires_at_utc"], "2026-11-23T14:59:59Z")
        XCTAssertEqual(out.expiresAt, Fixtures.utc("2026-11-23T15:00:00Z"))
        XCTAssertEqual(gen.inspect(fileBytes: out.fileBytes, publicKeys: [PublicKeyRef(keyId: "k", raw: pub)])?.check, .verified)
    }

    func testRentalDeskRejectsFutureStartAndRequiresLabel() {
        let gen = RentalDeskLegacyGenerator()
        let now = Fixtures.utc("2026-10-23T05:00:00Z")
        var r = LicenseRequest(productCode: "", pcScheme: .rentaldeskMachineV0, pcRaw: "ABCD2EFGH3IJKL4MNOP5",
                               pcNormalized: "ABCD2EFGH3IJKL4MNOP5", issuedAt: now, startsAt: now.addingTimeInterval(3600 * 24),
                               expiresAt: nil, licensee: nil, edition: "standard", maxVersion: nil)
        let issues = gen.validate(r, now: now)
        XCTAssertTrue(issues.contains { $0.field == .start })
        XCTAssertTrue(issues.contains { $0.field == .licensee })
        r.startsAt = now
        r.licensee = "OO렌탈"
        XCTAssertEqual(gen.validate(r, now: now), [])
    }

    /// `tools/verify_generated_with_apps.sh` 가 환경 변수로 폴더를 주면, 관리 프로그램(Swift)이 새로 서명한 파일을 저장한다.
    /// 그 파일을 각 앱 저장소의 검증 코드(verifyLicense, verify_license)로 다시 확인한다.
    func testExportGeneratedFilesForAppVerification() throws {
        guard let dir = ProcessInfo.processInfo.environment["LMS_EXPORT_FIXTURES_DIR"] else {
            throw XCTSkip("LMS_EXPORT_FIXTURES_DIR 없음(앱 교차 검증 스크립트에서만 실행)")
        }
        let out = URL(fileURLWithPath: dir)
        let rc = try Fixtures.json("docs/legacy-fixtures/reviewcut-legacy.json")
        let (seed, _, keyId) = try loadKey(rc)
        let now = Fixtures.utc("2026-10-23T05:00:00Z")
        let rcFile = try ReviewCutLegacyGenerator().generate(
            LicenseRequest(productCode: "", pcScheme: .reviewcutInstallId, pcRaw: "VRN-7KQ2-M9XA-3PDF", pcNormalized: "VRN-7KQ2-M9XA-3PDF",
                           issuedAt: now, startsAt: now, expiresAt: nil, licensee: "한글 \"따옴표\" / 😀", edition: "full", maxVersion: nil),
            signing: SigningMaterial(keyId: keyId!, privateKey: Ed25519Keys.privateKey(seed: seed)), now: now)
        try rcFile.fileBytes.write(to: out.appendingPathComponent("reviewcut.json"))

        let rdFile = try RentalDeskLegacyGenerator().generate(
            LicenseRequest(productCode: "", pcScheme: .rentaldeskMachineV0, pcRaw: "ABCD2EFGH3IJKL4MNOP5", pcNormalized: "ABCD2EFGH3IJKL4MNOP5",
                           issuedAt: now, startsAt: now, expiresAt: nil, licensee: "OO렌탈 \"본점\" / ☕", edition: "standard", maxVersion: "1.0"),
            signing: SigningMaterial(keyId: "rentaldesk-2026", privateKey: Ed25519Keys.privateKey(seed: seed)), now: now)
        try rdFile.fileBytes.write(to: out.appendingPathComponent("rentaldesk.json"))
    }

    // MARK: 자동 판별

    func testInspectAnyDetectsFormats() throws {
        let rc = try Fixtures.json("docs/legacy-fixtures/reviewcut-legacy.json")
        let rd = try Fixtures.json("docs/legacy-fixtures/rentaldesk-legacy.json")
        let rcText = try XCTUnwrap(rc["cases"]?.arrayValue.first?["file_text"]?.stringValue)
        let rdText = try XCTUnwrap(rd["cases"]?.arrayValue.first?["file_text"]?.stringValue)
        XCTAssertEqual(GeneratorRegistry.inspectAny(fileBytes: Data(rcText.utf8), publicKeys: [])?.generatorID, .reviewcutLegacy)
        XCTAssertEqual(GeneratorRegistry.inspectAny(fileBytes: Data(rdText.utf8), publicKeys: [])?.generatorID, .rentaldeskLegacy)
        XCTAssertEqual(GeneratorRegistry.inspectAny(fileBytes: Data(rdText.utf8), publicKeys: [])?.check, .unknownKey)
        XCTAssertNil(GeneratorRegistry.inspectAny(fileBytes: Data("hello".utf8), publicKeys: []))
        XCTAssertNil(GeneratorRegistry.inspectAny(fileBytes: Data("{\"a\":1}".utf8), publicKeys: []))
    }
}
