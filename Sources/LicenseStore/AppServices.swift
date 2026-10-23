import Foundation
import LicenseCore

/// 앱이 쓰는 서비스 묶음(UI ↔ 업무 규칙 ↔ 데이터 접근 ↔ 생성기 분리)
public final class AppServices {
    public let database: AppDatabase
    public let paths: AppPaths
    public let keyStore: SecretKeyStore
    public let isDemo: Bool
    public let now: Clock

    public let products: ProductService
    public let customers: CustomerService
    public let licenses: LicenseService
    public let queries: QueryService
    public let importExport: ImportExportService
    public let backup: BackupService
    public let settings: SettingsStore

    public init(database: AppDatabase, paths: AppPaths, keyStore: SecretKeyStore, isDemo: Bool, now: @escaping Clock = Date.init) {
        self.database = database
        self.paths = paths
        self.keyStore = keyStore
        self.isDemo = isDemo
        self.now = now
        products = ProductService(db: database, keyStore: keyStore, now: now)
        customers = CustomerService(db: database, now: now)
        licenses = LicenseService(db: database, products: products, now: now)
        queries = QueryService(db: database, now: now)
        importExport = ImportExportService(db: database, licenses: licenses, now: now)
        backup = BackupService(database: database, paths: paths, now: now)
        settings = SettingsStore(db: database)
    }

    /// 운영 데이터 열기(업그레이드 전 백업 포함)
    public static func openProduction(keychainService: String) throws -> AppServices {
        let paths = try AppPaths.standard()
        AppLogger.shared = AppLogger(dir: paths.logsDir)
        let db = try AppDatabase(path: paths.databaseURL.path, preMigrationBackupDir: paths.backupsDir)
        return AppServices(database: db, paths: paths, keyStore: KeychainKeyStore(service: keychainService), isDemo: false)
    }

    /// 데모 데이터베이스(운영 데이터와 분리된 폴더). 열 때마다 새로 만든다. 서명 키는 메모리에만 둔다.
    public static func openDemo() throws -> AppServices {
        let paths = try AppPaths.standard().demo()
        let fm = FileManager.default
        try? fm.removeItem(at: paths.databaseURL)
        let db = try AppDatabase(path: paths.databaseURL.path)
        let services = AppServices(database: db, paths: paths, keyStore: InMemoryKeyStore(), isDemo: true)
        try DemoData.seed(services)
        return services
    }
}

/// 데모 데이터(데모 DB 전용). 실제 고객 정보가 아닌 예시 값.
public enum DemoData {
    public static func seed(_ s: AppServices) throws {
        let t = s.now()
        let a = try s.products.create(ProductInput(code: "DEMO_NOTE", name: "데모 메모장", description: "데모 제품",
                                                   v1ProductCode: "DEMONOTE", defaultEdition: "standard", defaultMaxVersion: "1.0",
                                                   defaultTermMonths: 12, generators: [.lmsLicenseV1]))
        let b = try s.products.create(ProductInput(code: "DEMO_RENT", name: "데모 렌탈", description: "이전 형식 예시 포함",
                                                   v1ProductCode: "DEMORENT", defaultEdition: "standard",
                                                   generators: [.lmsLicenseV1, .rentaldeskLegacy]))
        let c = try s.products.create(ProductInput(code: "DEMO_EXT", name: "데모 외부 제품", description: "수동 등록 전용",
                                                   generators: [.manual]))
        try s.products.generateKey(productId: a.id!, keyId: "demo-note-2026")
        try s.products.generateKey(productId: b.id!, keyId: "demo-rent-2026")

        let c1 = try s.customers.create(CustomerInput(name: "가나다상사(예시)", contactPerson: "홍길동", memo: "데모 고객"))
        let c2 = try s.customers.create(CustomerInput(name: "라마바스튜디오(예시)"))
        let pc1 = try s.customers.addPC(customerId: c1.id!, PCInput(scheme: .lmsPcV1, number: PcIdV1.pcId(raw: "demo-pc-1"), alias: "사무실"))
        let pc2 = try s.customers.addPC(customerId: c1.id!, PCInput(scheme: .rentaldeskMachineV0, number: "ABCD2EFGH3IJKL4MNOP5", alias: "창고(구버전)"))
        let pc3 = try s.customers.addPC(customerId: c2.id!, PCInput(scheme: .lmsPcV1, number: PcIdV1.pcId(raw: "demo-pc-3"), alias: "작업실"))
        _ = try s.customers.addPC(customerId: c2.id!, PCInput(scheme: .manual, number: "00042-xyz", alias: "외부 제품용"))

        let today = LicenseTime.seoulDate(of: t)
        _ = try s.licenses.issue(IssueForm(customerId: c1.id!, productId: a.id!, pcId: pc1.id!, generatorId: .lmsLicenseV1,
                                           startsAt: LicenseTime.seoulMidnight(today.adding(days: -360)),
                                           expiresAt: LicenseTime.endExclusive(lastDay: today.adding(days: 5)),
                                           licensee: "가나다상사", edition: "standard", maxVersion: "1.0", memo: "곧 만료되는 예시"))
        _ = try s.licenses.issue(IssueForm(customerId: c1.id!, productId: b.id!, pcId: pc2.id!, generatorId: .rentaldeskLegacy,
                                           startsAt: t, expiresAt: nil, licensee: "가나다상사", edition: "standard", maxVersion: "1.0",
                                           memo: "이전 형식 예시"))
        _ = try s.licenses.issue(IssueForm(customerId: c2.id!, productId: a.id!, pcId: pc3.id!, generatorId: .lmsLicenseV1,
                                           startsAt: LicenseTime.seoulMidnight(today.adding(days: 10)), expiresAt: nil,
                                           licensee: "라마바스튜디오", edition: "standard", maxVersion: "", memo: "미래 시작 예시"))
        _ = c
    }
}
