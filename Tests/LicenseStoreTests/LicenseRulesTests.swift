import Foundation
import GRDB
import XCTest
@testable import LicenseCore
@testable import LicenseStore

/// CLAUDE.md 10절 검증 항목 중 업무 규칙
final class LicenseRulesTests: XCTestCase {
    func testThreeProductsTwoCustomersTwoPCsEach() throws {
        let env = try TestEnv()
        let p1 = try env.product("ALPHA")
        let p2 = try env.product("BETA")
        let p3 = try env.product("GAMMA")
        let c1 = try env.customer("고객1")
        let c2 = try env.customer("고객2")
        let pcs = [try env.pc(c1, raw: "c1-a"), try env.pc(c1, raw: "c1-b"), try env.pc(c2, raw: "c2-a"), try env.pc(c2, raw: "c2-b")]
        let end = LicenseTime.endExclusive(lastDay: day("2027-10-23"))
        _ = try env.issue(c1, p1, pcs[0], expires: end)
        _ = try env.issue(c1, p2, pcs[0], expires: end) // 같은 PC, 다른 제품
        _ = try env.issue(c1, p3, pcs[1], expires: nil)
        _ = try env.issue(c2, p1, pcs[2], expires: nil)
        _ = try env.issue(c2, p2, pcs[3], expires: end)

        XCTAssertEqual(try env.s.queries.licenses(LicenseFilter(productId: p1.id)).count, 2)
        XCTAssertEqual(try env.s.queries.licenses(LicenseFilter(pcId: pcs[0].id)).count, 2)
        XCTAssertEqual(try env.s.queries.licenses(LicenseFilter(customerId: c2.id)).count, 2)
        let stats = try env.s.queries.dashboard()
        XCTAssertEqual(stats.products, 3)
        XCTAssertEqual(stats.customers, 2)
        XCTAssertEqual(stats.validLicenses, 5)

        // PC 번호만으로 검색 → 고객·제품·발급 내역
        let search = try env.s.queries.search(pcs[0].displayNumber.lowercased())
        XCTAssertEqual(search.pcs.first?.customerName, "고객1")
        XCTAssertEqual(Set(search.licenses.map(\.productName)), ["제품 ALPHA", "제품 BETA"])
    }

    func testOverlapBlockedForSameProductAndPC() throws {
        let env = try TestEnv()
        let p = try env.product("ALPHA")
        let c = try env.customer("고객")
        let pc = try env.pc(c, raw: "x")
        let end = LicenseTime.endExclusive(lastDay: day("2026-12-31"))
        _ = try env.issue(c, p, pc, expires: end)
        // 겹침 → 차단
        XCTAssertThrowsError(try env.issue(c, p, pc, start: utc("2026-12-01T00:00:00Z"), expires: nil))
        // 이어지는 기간(만료 시각 = 새 시작) → 허용
        let next = try env.issue(c, p, pc, start: end, expires: LicenseTime.endExclusive(lastDay: day("2027-12-31")))
        XCTAssertEqual(next.startsDate, end)
        // 미래 시작 라이선스도 검사: 2027-06부터 영구(무한대)는 두 번째 기간과 겹친다
        XCTAssertThrowsError(try env.issue(c, p, pc, start: utc("2027-06-01T00:00:00Z"), expires: nil))
        XCTAssertNoThrow(try env.issue(c, p, pc, start: LicenseTime.endExclusive(lastDay: day("2027-12-31")), expires: nil))
        // 그 뒤로는 무엇도 겹친다(영구 = 무한대)
        XCTAssertThrowsError(try env.issue(c, p, pc, start: utc("2030-01-01T00:00:00Z"), expires: utc("2030-02-01T00:00:00Z")))
    }

    func testEffectiveStatusBoundaries() {
        let s = utc("2026-10-23T05:00:00Z")
        let e = utc("2026-11-24T15:00:00Z")
        XCTAssertEqual(EffectiveStatus.compute(status: .issued, startsAt: s, expiresAt: e, now: s.addingTimeInterval(-1)), .notYetValid)
        XCTAssertEqual(EffectiveStatus.compute(status: .issued, startsAt: s, expiresAt: e, now: s), .valid)
        XCTAssertEqual(EffectiveStatus.compute(status: .issued, startsAt: s, expiresAt: e, now: e.addingTimeInterval(-1)), .valid)
        XCTAssertEqual(EffectiveStatus.compute(status: .issued, startsAt: s, expiresAt: e, now: e), .expired)
        XCTAssertEqual(EffectiveStatus.compute(status: .issued, startsAt: s, expiresAt: nil, now: utc("9999-01-01T00:00:00Z")), .valid)
        XCTAssertEqual(EffectiveStatus.compute(status: .cancelled, startsAt: s, expiresAt: nil, now: s), .cancelled)
        XCTAssertEqual(EffectiveStatus.compute(status: .superseded, startsAt: s, expiresAt: e, now: e), .superseded)
    }

    func testPerpetualStoresNullExpiry() throws {
        let env = try TestEnv()
        let p = try env.product("ALPHA")
        let c = try env.customer("고객")
        let l = try env.issue(c, p, try env.pc(c, raw: "x"), expires: nil)
        XCTAssertNil(l.expiresAt)
        let stored = try env.s.database.read { db in try Row.fetchOne(db, sql: "SELECT expiresAt FROM license WHERE id = ?", arguments: [l.id]) }
        let value: String? = stored!["expiresAt"]
        XCTAssertNil(value)
    }

    func testRenewalAndReplacementTrackHistory() throws {
        let env = try TestEnv()
        let p = try env.product("ALPHA")
        let c = try env.customer("고객")
        let pcA = try env.pc(c, raw: "a")
        let pcB = try env.pc(c, raw: "b")
        let end = LicenseTime.endExclusive(lastDay: day("2027-01-31"))
        let first = try env.issue(c, p, pcA, expires: end)

        // 갱신(v1은 미래 시작 지원 → 기존 만료부터 이어서, 대체 없음)
        let plan = env.s.licenses.renewPlan(for: first, generatorId: .lmsLicenseV1, termMonths: 12)
        XCTAssertFalse(plan.mustSupersede)
        XCTAssertEqual(plan.suggestedStart, end)
        let renewed = try env.issue(c, p, pcA, start: plan.suggestedStart, expires: plan.suggestedExpiry,
                                    predecessor: Predecessor(licenseId: first.id!, kind: .renewal, reason: "1년 연장", supersede: false))
        // PC 교체(사유 필수, 기존 대체)
        XCTAssertThrowsError(try env.issue(c, p, pcB, expires: nil,
                                           predecessor: Predecessor(licenseId: renewed.id!, kind: .replacement, reason: "", supersede: true)))
        let moved = try env.issue(c, p, pcB, start: renewed.startsDate, expires: renewed.expiresDate,
                                  predecessor: Predecessor(licenseId: renewed.id!, kind: .replacement, reason: "메인보드 교체", supersede: true))

        XCTAssertEqual(try env.s.licenses.get(first.id!).status, .issued)
        XCTAssertEqual(try env.s.licenses.get(renewed.id!).status, .superseded)
        let detail = try env.s.queries.licenseDetail(moved.id!)
        XCTAssertEqual(detail.predecessors.first?.otherLicenseId, renewed.id)
        XCTAssertEqual(detail.predecessors.first?.relation.reason, "메인보드 교체")
        XCTAssertEqual(detail.predecessors.first?.relation.kind, .replacement)
        let renewedDetail = try env.s.queries.licenseDetail(renewed.id!)
        XCTAssertEqual(renewedDetail.predecessors.first?.otherLicenseId, first.id)
        XCTAssertEqual(renewedDetail.successors.first?.otherLicenseId, moved.id)
        XCTAssertTrue(renewedDetail.auditLogs.contains { $0.action == "supersede" && $0.reason == "메인보드 교체" })
    }

    func testLegacyRenewalMustSupersede() throws {
        let env = try TestEnv()
        let p = try env.product("RENT", generators: [.lmsLicenseV1, .rentaldeskLegacy])
        let c = try env.customer("고객")
        let pc = try env.pc(c, raw: "ABCD2EFGH3IJKL4MNOP5", scheme: .rentaldeskMachineV0)
        let end = LicenseTime.endExclusive(lastDay: day("2026-11-23"))
        let first = try env.issue(c, p, pc, expires: end, generator: .rentaldeskLegacy)
        let plan = env.s.licenses.renewPlan(for: first, generatorId: .rentaldeskLegacy, termMonths: 1)
        XCTAssertTrue(plan.mustSupersede)
        XCTAssertEqual(plan.suggestedStart, env.clock.now)
        // 대체하지 않으면 겹쳐서 막힌다
        XCTAssertThrowsError(try env.issue(c, p, pc, start: plan.suggestedStart, expires: plan.suggestedExpiry, generator: .rentaldeskLegacy,
                                           predecessor: Predecessor(licenseId: first.id!, kind: .renewal, reason: "", supersede: false)))
        let second = try env.issue(c, p, pc, start: plan.suggestedStart, expires: plan.suggestedExpiry, generator: .rentaldeskLegacy,
                                   predecessor: Predecessor(licenseId: first.id!, kind: .renewal, reason: "1개월 연장", supersede: true))
        XCTAssertEqual(try env.s.licenses.get(first.id!).status, .superseded)
        // 파일에는 23:59:59, 관리 DB에는 다음 날 00:00
        // 1개월: 발급일(서울 2026-10-23) + 1개월 같은 날짜(2026-11-23)까지 사용
        XCTAssertEqual(second.conditions["expires_at_utc"], "2026-11-23T14:59:59Z")
        XCTAssertEqual(second.expiresAt, "2026-11-23T15:00:00Z")
    }

    func testFailureMidTransactionLeavesNothing() throws {
        let env = try TestEnv()
        let p = try env.product("ALPHA")
        let c = try env.customer("고객")
        let pcA = try env.pc(c, raw: "a")
        let pcB = try env.pc(c, raw: "b")
        let old = try env.issue(c, p, pcA, expires: nil)
        let before = try env.licenseCount()
        struct Boom: Error {}
        env.s.licenses.failpoint = { point in if point == "before-insert" { throw Boom() } }
        XCTAssertThrowsError(try env.issue(c, p, pcB, expires: nil,
                                           predecessor: Predecessor(licenseId: old.id!, kind: .replacement, reason: "교체", supersede: true)))
        env.s.licenses.failpoint = nil
        XCTAssertEqual(try env.s.licenses.get(old.id!).status, .issued, "실패 시 기존 라이선스는 유지")
        XCTAssertEqual(try env.licenseCount(), before)
        let relations = try env.s.database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM license_relation")! }
        XCTAssertEqual(relations, 0)

        // 서명 키가 없으면 생성 단계에서 실패 → 아무것도 바뀌지 않음
        let noKey = try env.product("NOKEY", key: false)
        XCTAssertThrowsError(try env.issue(c, noKey, pcA, expires: nil))
        XCTAssertEqual(try env.licenseCount(), before)
    }

    func testDuplicateRequestTokenSavesOnce() throws {
        let env = try TestEnv()
        let p = try env.product("ALPHA")
        let c = try env.customer("고객")
        let pc = try env.pc(c, raw: "x")
        let token = UUID().uuidString
        let a = try env.issue(c, p, pc, expires: nil, token: token)
        let b = try env.issue(c, p, pc, expires: nil, token: token)
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(try env.licenseCount(), 1)
    }

    func testCancelledAndSupersededExcludedFromCounts() throws {
        let env = try TestEnv()
        let p = try env.product("ALPHA")
        let c = try env.customer("고객")
        let soon = env.clock.now.addingTimeInterval(3 * 86_400)
        let l1 = try env.issue(c, p, try env.pc(c, raw: "1"), expires: soon)
        let l2 = try env.issue(c, p, try env.pc(c, raw: "2"), expires: soon)
        let pc3 = try env.pc(c, raw: "3")
        _ = try env.issue(c, p, pc3, expires: soon)
        XCTAssertEqual(try env.s.queries.dashboard().expiring7, 3)
        XCTAssertThrowsError(try env.s.licenses.cancel(licenseId: l1.id!, reason: "  "))
        try env.s.licenses.cancel(licenseId: l1.id!, reason: "환불")
        _ = try env.issue(c, p, try env.pc(c, raw: "2b"), expires: nil,
                          predecessor: Predecessor(licenseId: l2.id!, kind: .replacement, reason: "교체", supersede: true))
        let stats = try env.s.queries.dashboard()
        XCTAssertEqual(stats.expiring7, 1)
        XCTAssertEqual(stats.expiring30, 1)
        XCTAssertEqual(stats.validLicenses, 2)
        let expiring = try env.s.queries.licenses(LicenseFilter(expiringWithinDays: 30, sort: .expiresSoon))
        XCTAssertEqual(expiring.map(\.license.status), [.issued])
        // 취소 기록은 남는다
        XCTAssertEqual(try env.s.licenses.get(l1.id!).status, .cancelled)
        XCTAssertEqual(try env.s.licenses.get(l1.id!).statusReason, "환불")
        // 취소된 라이선스는 다시 취소·대체할 수 없다
        XCTAssertThrowsError(try env.s.licenses.cancel(licenseId: l1.id!, reason: "다시"))
    }

    func testUnsupportedConditionsBlockedBeforeIssue() throws {
        let env = try TestEnv()
        let p = try env.product("RC", generators: [.lmsLicenseV1, .reviewcutLegacy])
        let c = try env.customer("고객")
        let pc = try env.pc(c, raw: "VRN-7KQ2-M9XA-3PDF", scheme: .reviewcutInstallId)
        let form = IssueForm(customerId: c.id!, productId: p.id!, pcId: pc.id!, generatorId: .reviewcutLegacy,
                             startsAt: env.clock.now, expiresAt: env.clock.now.addingTimeInterval(86_400 * 30))
        XCTAssertFalse(env.s.licenses.check(form).isEmpty)
        XCTAssertThrowsError(try env.s.licenses.issue(form))
        XCTAssertEqual(try env.licenseCount(), 0)
        // 다른 체계 PC에 v1 발급 불가
        var v1 = form
        v1.generatorId = .lmsLicenseV1
        v1.expiresAt = nil
        XCTAssertTrue(env.s.licenses.check(v1).contains { $0.field == .pc })
        // 영구 ReviewCut 이전 형식은 가능
        var ok = form
        ok.expiresAt = nil
        let l = try env.s.licenses.issue(ok)
        XCTAssertEqual(l.verification, .verified)
        XCTAssertNotNil(l.licenseFile)
    }

    func testDuplicatePCAcrossCustomersShowsOwner() throws {
        let env = try TestEnv()
        let c1 = try env.customer("원래 고객")
        let c2 = try env.customer("원래 고객") // 같은 이름도 다른 고객
        XCTAssertNotEqual(c1.id, c2.id)
        _ = try env.pc(c1, raw: "same")
        XCTAssertThrowsError(try env.pc(c2, raw: "same")) { error in
            guard case StoreError.duplicatePC(let owner, let name) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(owner, c1.id)
            XCTAssertEqual(name, "원래 고객")
        }
        // 정규화 규칙: 소문자·하이픈 입력도 같은 PC로 판단
        let display = PcScheme.lmsPcV1.display(normalized: PcIdV1.pcId(raw: "same")).lowercased()
        XCTAssertThrowsError(try env.s.customers.addPC(customerId: c2.id!, PCInput(scheme: .lmsPcV1, number: display)))
    }

    func testIssuedLicenseIsImmutableAndPcNumberLocked() throws {
        let env = try TestEnv()
        let p = try env.product("ALPHA")
        let c = try env.customer("고객")
        let pc = try env.pc(c, raw: "x")
        let l = try env.issue(c, p, pc, expires: nil)
        XCTAssertThrowsError(try env.s.database.write { db in
            try db.execute(sql: "UPDATE license SET expiresAt = '2099-01-01T00:00:00Z' WHERE id = ?", arguments: [l.id])
        })
        XCTAssertThrowsError(try env.s.database.write { db in
            try db.execute(sql: "UPDATE customer_pc SET numberNormalized = 'ZZZZZZZZZZZZZZZZZZZZZZZZZ' WHERE id = ?", arguments: [pc.id])
        })
        XCTAssertThrowsError(try env.s.database.write { db in try db.execute(sql: "DELETE FROM license") })
        XCTAssertThrowsError(try env.s.database.write { db in try db.execute(sql: "DELETE FROM audit_log") })
        // 별칭·메모는 수정 가능
        XCTAssertNoThrow(try env.s.customers.updatePC(pc.id!, alias: "새 별칭", memo: "메모"))
        XCTAssertNoThrow(try env.s.licenses.updateMemo(licenseId: l.id!, memo: "메모"))
        // 이력이 있는 고객·제품은 삭제하지 않는다
        XCTAssertThrowsError(try env.s.customers.delete(c.id!))
        XCTAssertThrowsError(try env.s.products.delete(p.id!))
    }

    func testLicenseCustomerMustMatchPCOwner() throws {
        let env = try TestEnv()
        let p = try env.product("ALPHA")
        let c1 = try env.customer("A")
        let c2 = try env.customer("B")
        let pc = try env.pc(c1, raw: "x")
        let form = IssueForm(customerId: c2.id!, productId: p.id!, pcId: pc.id!, generatorId: .lmsLicenseV1,
                             startsAt: env.clock.now, expiresAt: nil)
        XCTAssertThrowsError(try env.s.licenses.issue(form))
    }

    func testIssuedV1FileVerifiesWithProductPublicKey() throws {
        let env = try TestEnv()
        let p = try env.product("ALPHA")
        let c = try env.customer("고객")
        let pc = try env.pc(c, raw: "x")
        let l = try env.issue(c, p, pc, start: utc("2026-11-01T15:00:00Z"), expires: LicenseTime.endExclusive(lastDay: day("2027-10-31")))
        let key = try XCTUnwrap(env.s.products.detail(p.id!).keys.first)
        let code = LmsLicenseV1.verify(fileBytes: try XCTUnwrap(l.licenseFile),
                                       publicKeys: [key.keyId: try XCTUnwrap(Ed25519Keys.publicKey(raw: key.publicKeyRaw))],
                                       productCode: "ALPHA", pcId: pc.numberNormalized, now: utc("2027-01-01T00:00:00Z"), appVersion: "1.0.0")
        XCTAssertEqual(code, .valid)
        XCTAssertEqual(l.conditions["starts_at"], "2026-11-01T15:00:00Z")
        XCTAssertEqual(l.conditions["expires_at"], "2027-10-31T15:00:00Z")
        XCTAssertEqual(l.effectiveStatus(now: env.clock.now), .notYetValid)
        XCTAssertEqual(l.signedPayload?.hasPrefix("lms-license-v1:"), true)
    }
}
