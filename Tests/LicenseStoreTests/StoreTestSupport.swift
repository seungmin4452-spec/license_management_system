import Foundation
import GRDB
import XCTest
@testable import LicenseCore
@testable import LicenseStore

final class TestClock {
    var now: Date
    init(_ s: String) { now = LicenseTime.parseUTC(s)! }
    func advance(days: Double) { now = now.addingTimeInterval(days * 86_400) }
}

func utc(_ s: String) -> Date { LicenseTime.parseUTC(s)! }

/// 테스트 환경: 메모리 DB 또는 임시 폴더의 파일 DB, 메모리 키 저장소, 고정 시계
final class TestEnv {
    let clock: TestClock
    let services: AppServices
    let tempDir: URL?

    init(file: Bool = false, now: String = "2026-10-23T05:00:00Z") throws {
        let c = TestClock(now)
        clock = c
        if file {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lms-test-\(UUID().uuidString)")
            let paths = AppPaths(root: dir)
            try paths.createDirectories()
            tempDir = dir
            let db = try AppDatabase(path: paths.databaseURL.path, preMigrationBackupDir: paths.backupsDir)
            services = AppServices(database: db, paths: paths, keyStore: InMemoryKeyStore(), isDemo: false, now: { c.now })
        } else {
            tempDir = nil
            let db = try AppDatabase.inMemory()
            let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("lms-mem-\(UUID().uuidString)"))
            services = AppServices(database: db, paths: paths, keyStore: InMemoryKeyStore(), isDemo: false, now: { c.now })
        }
    }

    deinit {
        if let d = tempDir { try? FileManager.default.removeItem(at: d) }
    }

    var s: AppServices { services }

    // 기본 데이터

    @discardableResult
    func product(_ code: String, generators: Set<GeneratorID> = [.lmsLicenseV1], v1: String? = nil, key: Bool = true) throws -> Product {
        let p = try s.products.create(ProductInput(code: code, name: "제품 \(code)", v1ProductCode: v1 ?? code,
                                                   defaultEdition: "standard", generators: generators))
        if key && generators.contains(where: { $0 != .manual }) {
            try s.products.generateKey(productId: p.id!, keyId: code.lowercased().replacingOccurrences(of: "_", with: "-") + "-2026")
        }
        return p
    }

    func customer(_ name: String) throws -> Customer { try s.customers.create(CustomerInput(name: name)) }

    func pc(_ c: Customer, raw: String, scheme: PcScheme = .lmsPcV1) throws -> CustomerPC {
        let number = scheme == .lmsPcV1 ? PcIdV1.pcId(raw: raw) : raw
        return try s.customers.addPC(customerId: c.id!, PCInput(scheme: scheme, number: number))
    }

    func issue(_ c: Customer, _ p: Product, _ pc: CustomerPC, start: Date? = nil, expires: Date?, generator: GeneratorID = .lmsLicenseV1,
               token: String = UUID().uuidString, predecessor: Predecessor? = nil, licensee: String = "테스트 고객") throws -> License {
        try s.licenses.issue(IssueForm(customerId: c.id!, productId: p.id!, pcId: pc.id!, generatorId: generator,
                                       startsAt: start ?? clock.now, expiresAt: expires, licensee: licensee,
                                       edition: "standard", requestToken: token, predecessor: predecessor))
    }

    func licenseCount() throws -> Int {
        try s.database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM license")! }
    }
}

func day(_ s: String) -> CivilDate { CivilDate(string: s)! }
