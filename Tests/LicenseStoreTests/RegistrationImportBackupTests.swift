import CryptoKit
import Foundation
import GRDB
import XCTest
@testable import LicenseCore
@testable import LicenseStore

final class RegistrationImportBackupTests: XCTestCase {
    // MARK: 수동 등록

    func testManualRegistrationVerifiedAndUnverified() throws {
        let env = try TestEnv()
        let p = try env.product("ALPHA")
        let c = try env.customer("고객")
        let pc = try env.pc(c, raw: "x")
        // 같은 제품 키로 만든 파일(다른 DB에서 발급했다고 가정): 먼저 발급 → 취소 → 파일만 꺼내 새 PC 기록 없이 재사용하지 않고, 생성기로 직접 만든다
        let (material, _) = try env.s.products.signingMaterial(productId: p.id!)
        let req = LicenseRequest(productCode: "ALPHA", pcScheme: .lmsPcV1, pcRaw: pc.numberRaw, pcNormalized: pc.numberNormalized,
                                 issuedAt: env.clock.now, startsAt: env.clock.now,
                                 expiresAt: LicenseTime.endExclusive(lastDay: day("2027-10-22")), licensee: "고객", edition: "standard",
                                 maxVersion: nil)
        let file = try LmsLicenseV1Generator().generate(req, signing: material, now: env.clock.now)

        // 미리보기: 서명 확인 + 내용 자동 채움
        let ins = try XCTUnwrap(env.s.licenses.inspect(fileBytes: file.fileBytes, productId: p.id))
        XCTAssertEqual(ins.check, .verified)
        XCTAssertEqual(ins.pcNumber, pc.numberNormalized)

        let verified = try env.s.licenses.registerManual(ManualForm(customerId: c.id!, productId: p.id!, pcId: pc.id!,
                                                                    fileBytes: file.fileBytes, fileName: "a.json",
                                                                    startsAt: utc("2000-01-01T00:00:00Z"), expiresAt: nil))
        XCTAssertEqual(verified.verification, .verified)
        XCTAssertEqual(verified.fileLicenseId, file.licenseIdInFile)
        XCTAssertEqual(verified.expiresAt, "2027-10-22T15:00:00Z", "검증된 파일의 기간을 쓴다(입력 무시)")
        // 같은 파일 다시 등록 → 거부
        XCTAssertThrowsError(try env.s.licenses.registerManual(ManualForm(customerId: c.id!, productId: p.id!, pcId: pc.id!,
                                                                          fileBytes: file.fileBytes, fileName: "a.json",
                                                                          startsAt: env.clock.now, expiresAt: nil)))

        // 변조된 파일 → 호환성 미검증
        var text = file.fileText
        text = text.replacingOccurrences(of: "\"licensee\": \"고객\"", with: "\"licensee\": \"다른 고객\"")
        let pc2 = try env.pc(c, raw: "y")
        let tampered = try env.s.licenses.registerManual(ManualForm(customerId: c.id!, productId: p.id!, pcId: pc2.id!,
                                                                    fileBytes: Data(text.utf8), fileName: "b.json",
                                                                    startsAt: env.clock.now, expiresAt: nil))
        XCTAssertEqual(tampered.verification, .unverified)
        XCTAssertTrue(tampered.verificationDetail.contains("미검증"))
        XCTAssertNil(tampered.fileLicenseId)

        // 알 수 없는 형식 → 미검증, 입력한 관리상 기간 사용
        let pc3 = try env.pc(c, raw: "z")
        let unknown = try env.s.licenses.registerManual(ManualForm(customerId: c.id!, productId: p.id!, pcId: pc3.id!,
                                                                   fileBytes: Data("LICENSE-KEY-1234".utf8), fileName: "key.txt",
                                                                   startsAt: env.clock.now, expiresAt: env.clock.now.addingTimeInterval(86_400)))
        XCTAssertEqual(unknown.verification, .unverified)
        XCTAssertNotNil(unknown.expiresAt)
        XCTAssertEqual(unknown.licenseFile, Data("LICENSE-KEY-1234".utf8))
    }

    func testManualRegistrationRejectsWrongPC() throws {
        let env = try TestEnv()
        let p = try env.product("ALPHA")
        let c = try env.customer("고객")
        let pc = try env.pc(c, raw: "x")
        let other = try env.pc(c, raw: "other")
        let (material, _) = try env.s.products.signingMaterial(productId: p.id!)
        let req = LicenseRequest(productCode: "ALPHA", pcScheme: .lmsPcV1, pcRaw: pc.numberRaw, pcNormalized: pc.numberNormalized,
                                 issuedAt: env.clock.now, startsAt: env.clock.now, expiresAt: nil, licensee: nil,
                                 edition: "standard", maxVersion: nil)
        let file = try LmsLicenseV1Generator().generate(req, signing: material, now: env.clock.now)
        XCTAssertThrowsError(try env.s.licenses.registerManual(ManualForm(customerId: c.id!, productId: p.id!, pcId: other.id!,
                                                                          fileBytes: file.fileBytes, fileName: nil,
                                                                          startsAt: env.clock.now, expiresAt: nil)))
    }

    func testBatchRegisterReviewCutLegacyFixtures() throws {
        let env = try TestEnv()
        let p = try env.product("REVIEWCUT", generators: [.lmsLicenseV1, .reviewcutLegacy], key: false)
        let fixture = try JSONParser.parse(Data(contentsOf: Self.repoRoot.appendingPathComponent("docs/legacy-fixtures/reviewcut-legacy.json")))
        let key = try XCTUnwrap(fixture.objectValue?["test_key"]?.objectValue)
        try env.s.products.registerExpectedPublicKey(productId: p.id!, keyId: key["key_id"]!.stringValue!,
                                                     publicKey: key["public_key_hex"]!.stringValue!)
        guard case .array(let cases)? = fixture.objectValue?["cases"] else { return XCTFail() }
        // 첫 예제 파일(서명 확인됨) 등록
        let first = try XCTUnwrap(cases.first?.objectValue?["file_text"]?.stringValue)
        let items = try env.s.licenses.prepareBatch(files: [(name: "license-1.json", data: Data(first.utf8))], productId: p.id!)
        XCTAssertEqual(items.first?.isVerified, true)
        XCTAssertEqual(items.first?.customer, .new("OO스튜디오"))
        XCTAssertEqual(try env.s.licenses.commitBatch(items, productId: p.id!), 1)
        // 같은 파일 다시 → 건너뜀
        let again = try env.s.licenses.prepareBatch(files: [(name: "license-1.json", data: Data(first.utf8))], productId: p.id!)
        XCTAssertNotNil(again.first?.alreadyRegistered)
        XCTAssertEqual(try env.s.licenses.commitBatch(again, productId: p.id!), 0)
        // 변조 파일은 일괄 등록 거부(전체 저장 안 함)
        let bad = first.replacingOccurrences(of: "OO스튜디오", with: "XX")
        let badItems = try env.s.licenses.prepareBatch(files: [(name: "bad.json", data: Data(bad.utf8))], productId: p.id!)
        XCTAssertThrowsError(try env.s.licenses.commitBatch(badItems, productId: p.id!))
        XCTAssertEqual(try env.licenseCount(), 1)
    }

    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    // MARK: 서명 키

    func testKeyImportRejectsMismatchAndSecretNeverInDB() throws {
        let env = try TestEnv(file: true)
        let p = try env.product("RENTALDESK", generators: [.lmsLicenseV1, .rentaldeskLegacy], key: false)
        // 알려진 고객 앱 공개키(RENTALDESK / rentaldesk-2026)와 다른 키 → 거부
        let wrongSeed = Data(SHA256.hash(data: Data("wrong".utf8)))
        let json = "{\"private_key_hex\": \"\(TextRules.hex(wrongSeed))\"}"
        XCTAssertThrowsError(try env.s.products.importKey(productId: p.id!, keyId: "rentaldesk-2026", fileContents: Data(json.utf8),
                                                         expectedPublicKey: nil))
        XCTAssertTrue(try env.s.products.detail(p.id!).keys.isEmpty)

        // 확인용 공개키를 맞게 주면 가져옴
        let goodSeed = Data(SHA256.hash(data: Data("good".utf8)))
        let pub = try Ed25519Keys.privateKey(seed: goodSeed).publicKey.rawRepresentation
        let pem = Ed25519Keys.pkcs8PEM(seed: goodSeed)
        let k = try env.s.products.importKey(productId: p.id!, keyId: "other-2026", fileContents: Data(pem.utf8),
                                             expectedPublicKey: TextRules.hex(pub))
        XCTAssertEqual(k.publicKeyHex, TextRules.hex(pub))

        // 발급·백업 후 DB 파일·백업 파일에 비밀키 바이트·hex가 없다
        let c = try env.customer("고객")
        _ = try env.issue(c, p, try env.pc(c, raw: "x"), expires: nil)
        let backupURL = env.tempDir!.appendingPathComponent("manual.sqlite")
        try env.s.backup.manualBackup(to: backupURL)
        let csv = env.s.importExport.exportCSV(try env.s.queries.licenses(LicenseFilter()))
        for url in [URL(fileURLWithPath: env.s.database.path!), backupURL] {
            let bytes = try Data(contentsOf: url)
            XCTAssertNil(bytes.range(of: goodSeed), "seed bytes in \(url.lastPathComponent)")
            XCTAssertNil(bytes.range(of: Data(TextRules.hex(goodSeed).utf8)), "seed hex in \(url.lastPathComponent)")
            XCTAssertNil(bytes.range(of: Data(pem.utf8.prefix(60))), "pem in \(url.lastPathComponent)")
        }
        XCTAssertNil(csv.range(of: Data(TextRules.hex(goodSeed).utf8)))
        let logs = (try? FileManager.default.contentsOfDirectory(at: env.s.paths.logsDir, includingPropertiesForKeys: nil)) ?? []
        for log in logs { XCTAssertNil(try Data(contentsOf: log).range(of: Data(TextRules.hex(goodSeed).utf8))) }
    }

    func testExpectedPublicKeyThenImportSecret() throws {
        let env = try TestEnv()
        let p = try env.product("NEWAPP", key: false)
        let seed = Data(SHA256.hash(data: Data("seed".utf8)))
        let pub = try Ed25519Keys.privateKey(seed: seed).publicKey.rawRepresentation
        try env.s.products.registerExpectedPublicKey(productId: p.id!, keyId: "newapp-2026", publicKey: Ed25519Keys.spkiPEM(publicKeyRaw: pub))
        // 비밀키 없음 → 발급 불가
        let c = try env.customer("고객")
        let pc = try env.pc(c, raw: "x")
        XCTAssertThrowsError(try env.issue(c, p, pc, expires: nil))
        // 다른 키 → 거부, 맞는 키 → 채움
        XCTAssertThrowsError(try env.s.products.importKey(productId: p.id!, keyId: "newapp-2026",
                                                         fileContents: Data(TextRules.hex(Data(repeating: 7, count: 32)).utf8), expectedPublicKey: nil))
        try env.s.products.importKey(productId: p.id!, keyId: "newapp-2026", fileContents: Data(TextRules.hex(seed).utf8), expectedPublicKey: nil)
        XCTAssertNoThrow(try env.issue(c, p, pc, expires: nil))
    }

    // MARK: CSV

    func testCSVImportAllOrNothingAndNoDuplicatesOnReimport() throws {
        let env = try TestEnv()
        let p = try env.product("ALPHA")
        _ = p
        let good = """
        customer_name,product_code,pc_scheme,pc_number,starts_at,last_use_day,status,source_id
        가나다,ALPHA,manual,00123-ab,2026-01-01,2026-12-31,issued,r1
        라마바,ALPHA,lms-pc-v1,\(PcScheme.lmsPcV1.display(normalized: PcIdV1.pcId(raw: "p2"))),2026-01-01,,issued,r2
        """
        let bad = good + "\n사바아,UNKNOWN,manual,0099,2026-13-01,,issued,r3\n"
        let badTable = try CSV.parse(Data(bad.utf8))
        let badMapping = ImportExportService.defaultMapping(for: badTable, preset: .standard, sourceName: "bad.csv")
        let plan = try env.s.importExport.plan(badTable, badMapping)
        XCTAssertTrue(plan.hasErrors)
        let errorRow = try XCTUnwrap(plan.rows.first { !$0.errors.isEmpty })
        XCTAssertEqual(errorRow.line, 4)
        XCTAssertTrue(errorRow.errors.contains { $0.contains("제품") })
        XCTAssertTrue(errorRow.errors.contains { $0.contains("시작 시각") })
        XCTAssertThrowsError(try env.s.importExport.commit(badTable, badMapping))
        XCTAssertEqual(try env.licenseCount(), 0)
        XCTAssertEqual(try env.s.customers.list().count, 0, "실패 시 고객도 만들지 않는다")

        let table = try CSV.parse(Data(good.utf8))
        let mapping = ImportExportService.defaultMapping(for: table, preset: .standard, sourceName: "good.csv")
        XCTAssertEqual(try env.s.importExport.commit(table, mapping), 2)
        // 같은 파일 다시 → 중복 없음(건너뜀)
        let again = try env.s.importExport.plan(table, mapping)
        XCTAssertFalse(again.hasErrors)
        XCTAssertEqual(again.skipCount, 2)
        XCTAssertEqual(try env.s.importExport.commit(table, mapping), 0)
        XCTAssertEqual(try env.licenseCount(), 2)

        // 앞자리 0·원본 형식 보존: 저장 → 검색 → 내보내기 → 다시 읽기
        let found = try env.s.queries.licenses(LicenseFilter(query: "00123"))
        XCTAssertEqual(found.first?.pcNumber, "00123-ab")
        let exported = env.s.importExport.exportCSV(found)
        let back = try CSV.parse(exported)
        let col = try XCTUnwrap(back.header.firstIndex(of: "pc_number"))
        XCTAssertEqual(back.rows.first?[col], "00123-ab")
        let lastCol = try XCTUnwrap(back.header.firstIndex(of: "last_use_day"))
        XCTAssertEqual(back.rows.first?[lastCol], "2026-12-31")

        // 다른 DB로 왕복 가져오기(고객 ID 열 제외)
        let env2 = try TestEnv()
        _ = try env2.product("ALPHA")
        var m2 = ImportExportService.defaultMapping(for: back, preset: .standard, sourceName: "export.csv")
        m2.columns[.customerId] = nil
        XCTAssertEqual(try env2.s.importExport.commit(back, m2), 1)
        let pc = try env2.s.database.read { db in try CustomerPC.fetchOne(db) }
        XCTAssertEqual(pc?.numberRaw, "00123-ab")
        XCTAssertEqual(pc?.scheme, .manual)
    }

    func testRentalDeskLedgerPreset() throws {
        let env = try TestEnv()
        let p = try env.product("RENTALDESK", generators: [.lmsLicenseV1, .rentaldeskLegacy], key: false)
        let pcV1 = PcScheme.lmsPcV1.display(normalized: PcIdV1.pcId(raw: "ledger"))
        let ledger = """
        license_id,issued_at_utc,customer_label,machine_code,edition,expires_at_utc,note,package,kmong_order,app_version,updates_through,format,starts_at_utc
        11111111-1111-4111-8111-111111111111,2026-09-01T01:00:00Z,OO렌탈,ABCD-2EFG-H3IJ-KL4M-NOP5,standard,2026-10-01T14:59:59Z,첫 발급,STANDARD,1001,1.0.0,1.0,legacy,
        22222222-2222-4222-8222-222222222222,2026-09-20T01:00:00Z,OO렌탈,ABCD-2EFG-H3IJ-KL4M-NOP5,standard,,업데이트 재발급,DELUXE,1002,1.0.0,1.0,legacy,
        33333333-3333-4333-8333-333333333333,2026-10-23T01:00:00Z,OO렌탈,\(pcV1),standard,2027-10-23T15:00:00Z,,,1003,1.0.0,1.0,v1,2026-10-23T01:00:00Z
        """
        let table = try CSV.parse(Data(ledger.utf8))
        var mapping = ImportExportService.defaultMapping(for: table, preset: .rentalDeskLedger, sourceName: "issued_licenses.csv")
        mapping.fixedProductId = p.id
        let plan = try env.s.importExport.plan(table, mapping)
        XCTAssertFalse(plan.hasErrors, "\(plan.rows.map(\.errors))")
        XCTAssertEqual(plan.newCustomerNames, ["OO렌탈"])
        XCTAssertEqual(try env.s.importExport.commit(table, mapping), 3)
        let rows = try env.s.queries.licenses(LicenseFilter(sort: .managementNo))
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(Set(rows.map(\.license.customerId)).count, 1, "파일 안 같은 이름 → 한 고객")
        let first = try XCTUnwrap(rows.first { $0.license.fileLicenseId == "11111111-1111-4111-8111-111111111111" })
        XCTAssertEqual(first.pcScheme, .rentaldeskMachineV0)
        XCTAssertEqual(first.license.expiresAt, "2026-10-01T15:00:00Z", "이전 형식 23:59:59 → 다음 날 00:00")
        XCTAssertEqual(first.license.externalRef, "1001")
        let v1 = try XCTUnwrap(rows.first { $0.license.fileLicenseId == "33333333-3333-4333-8333-333333333333" })
        XCTAssertEqual(v1.pcScheme, .lmsPcV1)
        XCTAssertEqual(v1.license.generatorId, "lms-license-v1")
        // 둘째(09-20 시작, 영구)가 첫째(10-01 만료)와 겹침 → 첫째를 대체됨으로 연결(재발급 이력)
        XCTAssertEqual(first.license.status, .superseded)
        // 재가져오기: 중복 없음
        XCTAssertEqual(try env.s.importExport.commit(table, mapping), 0)
    }

    func testCSVFormulaInjectionPolicy() throws {
        XCTAssertEqual(CSV.cell("=SUM(A1)"), "'=SUM(A1)")
        XCTAssertEqual(CSV.cell("+82-10"), "'+82-10")
        XCTAssertEqual(CSV.cell("@cmd"), "'@cmd")
        XCTAssertEqual(CSV.cell("00123"), "00123")
        XCTAssertEqual(CSV.cell("가,나"), "\"가,나\"")
        let data = CSV.write(header: ["a"], rows: [["=1+1"], ["0012"], ["한글 \"따옴표\""]])
        let back = try CSV.parse(data)
        XCTAssertEqual(back.rows.map { $0[0] }, ["=1+1", "0012", "한글 \"따옴표\""])
    }

    // MARK: 백업·복원

    func testBackupRestoreRoundTripAndRejectCorrupt() throws {
        let env = try TestEnv(file: true)
        let p = try env.product("ALPHA")
        let c = try env.customer("고객")
        let pc = try env.pc(c, raw: "x")
        let l = try env.issue(c, p, pc, expires: nil)
        let backupURL = env.tempDir!.appendingPathComponent("backup-1.sqlite")
        try env.s.backup.manualBackup(to: backupURL)
        let info = try env.s.backup.inspect(backupURL)
        XCTAssertEqual(info.licenses, 1)

        // 백업 이후 변경 → 복원하면 백업 시점으로
        try env.s.licenses.cancel(licenseId: l.id!, reason: "테스트")
        _ = try env.customer("나중 고객")
        let safety = try env.s.backup.restore(from: backupURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: safety.path), "복원 전 현재 데이터 백업")
        let restored = try env.s.licenses.get(l.id!)
        XCTAssertEqual(restored.status, .issued)
        XCTAssertEqual(restored.licenseFile, l.licenseFile, "라이선스 파일 BLOB 일치")
        XCTAssertEqual(try env.s.customers.list().count, 1)
        XCTAssertFalse(try env.s.queries.licenseDetail(l.id!).auditLogs.isEmpty, "이력 일치")

        // 손상 파일 → 거부, 현재 DB 유지
        let corrupt = env.tempDir!.appendingPathComponent("corrupt.sqlite")
        var bytes = try Data(contentsOf: backupURL)
        bytes.replaceSubrange(0..<16, with: Data(repeating: 0x41, count: 16))
        try bytes.write(to: corrupt)
        XCTAssertThrowsError(try env.s.backup.restore(from: corrupt))
        let text = env.tempDir!.appendingPathComponent("text.sqlite")
        try Data("hello".utf8).write(to: text)
        XCTAssertThrowsError(try env.s.backup.restore(from: text))
        XCTAssertEqual(try env.s.licenses.get(l.id!).status, .issued)

        // 더 새로운 버전 백업 → 거부
        let newer = env.tempDir!.appendingPathComponent("newer.sqlite")
        try FileManager.default.copyItem(at: backupURL, to: newer)
        let q = try DatabaseQueue(path: newer.path)
        try q.write { db in try db.execute(sql: "INSERT INTO grdb_migrations(identifier) VALUES ('v99-future')") }
        try q.close()
        XCTAssertThrowsError(try env.s.backup.restore(from: newer)) { error in
            XCTAssertTrue("\(error.localizedDescription)".contains("새로운 버전"))
        }
        XCTAssertEqual(try env.s.licenses.get(l.id!).status, .issued)
    }

    func testAutoBackupKeepsRecentN() throws {
        let env = try TestEnv(file: true)
        try env.s.settings.setAutoBackupKeep(3)
        for _ in 0..<5 {
            try env.s.backup.autoBackup()
            env.clock.advance(days: 1)
        }
        XCTAssertEqual(env.s.backup.autoBackups().count, 3)
    }

    func testDataPersistsAfterReopen() throws {
        let env = try TestEnv(file: true)
        let p = try env.product("ALPHA")
        let c = try env.customer("고객")
        _ = try env.issue(c, p, try env.pc(c, raw: "x"), expires: nil)
        let path = env.s.database.path!
        try env.s.database.close()
        let reopened = try AppDatabase(path: path)
        XCTAssertEqual(try reopened.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM license") }, 1)
        try reopened.close()
    }
}
