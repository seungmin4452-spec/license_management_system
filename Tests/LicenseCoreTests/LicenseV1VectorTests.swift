import CryptoKit
import Foundation
import XCTest
@testable import LicenseCore

/// `docs/license-v1-test-vectors.json` 전체 통과 확인.
/// 이 벡터는 RentalDesk(Python)·ReviewCut(TypeScript) 앱 구현도 통과한다 → 통과하면 고객 앱과 호환.
final class LicenseV1VectorTests: XCTestCase {
    var vectors: JSONObject!
    var publicKeys: [String: Curve25519.Signing.PublicKey] = [:]
    var seed = Data()

    override func setUpWithError() throws {
        vectors = try Fixtures.json("docs/license-v1-test-vectors.json")
        let key = try XCTUnwrap(vectors["test_key"]?.objectValue)
        let keyId = try XCTUnwrap(key["key_id"]?.stringValue)
        let pub = try XCTUnwrap(TextRules.dataFromHex(XCTUnwrap(key["public_key_hex"]?.stringValue)))
        seed = try XCTUnwrap(TextRules.dataFromHex(XCTUnwrap(key["seed_hex"]?.stringValue)))
        publicKeys = [keyId: try Curve25519.Signing.PublicKey(rawRepresentation: pub)]
        // seed → 공개키 계산이 벡터와 같아야 한다
        XCTAssertEqual(try Ed25519Keys.privateKey(seed: seed).publicKey.rawRepresentation, pub)
    }

    func testPcIdCases() throws {
        let cases = try XCTUnwrap(vectors["pc_id_cases"]).arrayValue
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let raw = try XCTUnwrap(c["raw"]?.stringValue)
            XCTAssertEqual(PcIdV1.deviceHash(raw: raw), c["device_hash"]?.stringValue)
            let id = PcIdV1.pcId(raw: raw)
            XCTAssertEqual(id, c["pc_id"]?.stringValue)
            XCTAssertEqual(PcScheme.lmsPcV1.display(normalized: id), c["display"]?.stringValue)
            // 표시 형식 → 정규화하면 원래 값
            XCTAssertEqual(PcScheme.lmsPcV1.normalize(c["display"]!.stringValue!.lowercased()), id)
        }
    }

    func testLicenseCases() throws {
        let cases = try XCTUnwrap(vectors["license_cases"]).arrayValue
        XCTAssertGreaterThanOrEqual(cases.count, 30)
        for c in cases {
            let name = c["name"]?.stringValue ?? "?"
            let file = try XCTUnwrap(c["file"], name)
            let ctx = try XCTUnwrap(c["context"], name)
            let expect = try XCTUnwrap(c["expect"]?.stringValue, name)

            // 1) 서명 대상 바이트 일치
            if let expectedMessage = c["message_utf8"]?.stringValue, let payload = file["payload"] {
                let message = try LmsLicenseV1.signingMessage(payload: payload)
                XCTAssertEqual(String(decoding: message, as: UTF8.self), expectedMessage, "message: \(name)")
            }

            // 2) 결과 코드 일치(객체 그대로, 그리고 파일 텍스트로 다시 써서)
            let now = Fixtures.utc(try XCTUnwrap(ctx["now"]?.stringValue))
            let code = LmsLicenseV1.verify(
                document: file, publicKeys: publicKeys,
                productCode: try XCTUnwrap(ctx["product_code"]?.stringValue),
                pcId: ctx["pc_id"]?.stringValue, now: now,
                appVersion: try XCTUnwrap(ctx["app_version"]?.stringValue))
            XCTAssertEqual(code.rawValue, expect, "code: \(name)")

            let text = Data(JSONWriter.pretty(file).utf8)
            let code2 = LmsLicenseV1.verify(
                fileBytes: text, publicKeys: publicKeys, productCode: ctx["product_code"]!.stringValue!,
                pcId: ctx["pc_id"]?.stringValue, now: now, appVersion: ctx["app_version"]!.stringValue!)
            XCTAssertEqual(code2.rawValue, expect, "text code: \(name)")
        }
    }

    /// CryptoKit 서명은 매번 다를 수 있으므로 "서명 대상 바이트 일치 + 공개키 검증 통과"로 판정한다.
    func testGeneratorProducesVerifiableFileWithSameMessage() throws {
        let gen = LmsLicenseV1Generator()
        let request = LicenseRequest(
            productCode: "TESTPRODUCT", pcScheme: .lmsPcV1, pcRaw: "7IO36-4GQ6P-GKV25-YX5MD-RQLS4",
            pcNormalized: "7IO364GQ6PGKV25YX5MDRQLS4",
            issuedAt: Fixtures.utc("2026-10-23T05:00:00Z"), startsAt: Fixtures.utc("2026-10-23T05:00:00Z"),
            expiresAt: Fixtures.utc("2026-11-24T15:00:00Z"), licensee: "OO렌탈", edition: "standard",
            maxVersion: "1.0", options: [:], licenseId: "6f1c2a4e-1b7d-4c55-9a51-0f2d3c4b5a69")
        XCTAssertEqual(gen.validate(request, now: Fixtures.utc("2026-10-23T05:00:00Z")), [])
        let signing = SigningMaterial(keyId: "test-2026", privateKey: try Ed25519Keys.privateKey(seed: seed))
        let out = try gen.generate(request, signing: signing, now: Fixtures.utc("2026-10-23T05:00:00Z"))

        // 벡터 "기간제 기간 안" 케이스와 같은 payload → 같은 서명 대상 바이트
        let cases = try XCTUnwrap(vectors["license_cases"]).arrayValue
        let term = try XCTUnwrap(cases.first { $0["name"]?.stringValue == "기간제 기간 안" })
        XCTAssertEqual(out.signedMessageText, term["message_utf8"]?.stringValue)

        let code = LmsLicenseV1.verify(fileBytes: out.fileBytes, publicKeys: publicKeys, productCode: "TESTPRODUCT",
                                       pcId: "7IO364GQ6PGKV25YX5MDRQLS4", now: Fixtures.utc("2026-10-25T00:00:00Z"),
                                       appVersion: "1.0.3")
        XCTAssertEqual(code, .valid)

        // 관리 프로그램의 검사 함수도 통과
        let inspected = try XCTUnwrap(gen.inspect(fileBytes: out.fileBytes,
                                                  publicKeys: [PublicKeyRef(keyId: "test-2026", raw: publicKeys["test-2026"]!.rawRepresentation)]))
        XCTAssertEqual(inspected.check, .verified)
        XCTAssertEqual(inspected.licenseId, "6f1c2a4e-1b7d-4c55-9a51-0f2d3c4b5a69")
        XCTAssertEqual(inspected.expiresAt, Fixtures.utc("2026-11-24T15:00:00Z"))
    }

    func testSpecialCharactersCanonical() throws {
        let gen = LmsLicenseV1Generator()
        var request = LicenseRequest(
            productCode: "TESTPRODUCT", pcScheme: .lmsPcV1, pcRaw: "x", pcNormalized: "7IO364GQ6PGKV25YX5MDRQLS4",
            issuedAt: Fixtures.utc("2026-10-23T05:00:00Z"), startsAt: Fixtures.utc("2026-10-23T05:00:00Z"),
            expiresAt: nil, licensee: "한글 \"따옴표\" \\ 역슬래시 / 슬래시 ☕", edition: "standard", maxVersion: nil,
            options: ["seats": "3", "z_note": "a/b"], licenseId: "6f1c2a4e-1b7d-4c55-9a51-0f2d3c4b5a69")
        let payload = gen.makePayload(request)
        let cases = try XCTUnwrap(vectors["license_cases"]).arrayValue
        let special = try XCTUnwrap(cases.first { $0["name"]?.stringValue == "특수 문자 정규화" })
        XCTAssertEqual(String(decoding: try LmsLicenseV1.signingMessage(payload: payload.json), as: UTF8.self),
                       special["message_utf8"]?.stringValue)
        // 생성기 입력 검사: 미래 시작 지원, 만료 <= 시작은 거부
        request.expiresAt = request.startsAt
        XCTAssertFalse(gen.validate(request, now: request.issuedAt).isEmpty)
    }
}
