import Foundation
import GRDB
import LicenseCore

/// 백업 파일 검사 결과
public struct BackupInspection: Equatable {
    public var url: URL
    public var migrations: [String]
    public var customers: Int
    public var products: Int
    public var licenses: Int
    public var lastActivity: String?
}

/// 백업·복원. SQLite 온라인 백업 API를 쓴다(실행 중인 DB 파일을 단순 복사하지 않음).
/// 서명 비밀키는 키체인에만 있으므로 백업에 들어가지 않는다.
public final class BackupService {
    let database: AppDatabase
    let paths: AppPaths
    let settings: SettingsStore
    let now: Clock

    public init(database: AppDatabase, paths: AppPaths, now: @escaping Clock = Date.init) {
        self.database = database
        self.paths = paths
        self.settings = SettingsStore(db: database)
        self.now = now
    }

    /// 원본 연결에서 대상 파일로 일관된 백업을 만든다. 임시 파일에 쓴 뒤 이름을 바꿔 반쯤 쓰인 파일이 남지 않게 한다.
    static func backup(from source: DatabaseQueue, to url: URL) throws {
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: tmp) }
        do {
            let dest = try DatabaseQueue(path: tmp.path)
            try source.backup(to: dest)
            try dest.close()
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
        } catch {
            throw StoreError.io("백업 파일을 만들지 못했습니다: \(error.localizedDescription)")
        }
    }

    /// 수동 백업(사용자가 고른 위치). 자동 삭제하지 않는다.
    public func manualBackup(to url: URL) throws {
        try Self.backup(from: database.dbQueue, to: url)
        try? database.write { db in
            try Audit.log(db, entity: "app", id: 0, action: "backup", summary: "수동 백업: \(url.lastPathComponent)", now: now())
        }
    }

    /// 자동 백업(종료 시). `Backups/auto-YYYYMMDD-HHMMSS.sqlite`, 최근 N개만 유지.
    @discardableResult
    public func autoBackup() throws -> URL {
        try FileManager.default.createDirectory(at: paths.backupsDir, withIntermediateDirectories: true)
        let url = paths.backupsDir.appendingPathComponent("auto-\(BackupNames.stamp(now())).sqlite")
        try Self.backup(from: database.dbQueue, to: url)
        try pruneAutoBackups(keep: settings.autoBackupKeep)
        return url
    }

    public func autoBackups() -> [URL] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: paths.backupsDir, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.lastPathComponent.hasPrefix("auto-") && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    public func pruneAutoBackups(keep: Int) throws {
        for old in autoBackups().dropFirst(max(1, keep)) {
            try FileManager.default.removeItem(at: old)
        }
    }

    // MARK: 복원

    /// 백업 무결성·스키마 버전·프로그램 호환성 확인. 원본 파일은 바꾸지 않는다(임시 복사본으로 검사).
    public func inspect(_ url: URL) throws -> BackupInspection {
        let (info, tmp) = try inspectCopy(url)
        try? FileManager.default.removeItem(at: tmp)
        return info
    }

    private func inspectCopy(_ url: URL) throws -> (BackupInspection, URL) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("lms-restore-\(UUID().uuidString).sqlite")
        do { try fm.copyItem(at: url, to: tmp) } catch {
            throw StoreError.restoreRejected("백업 파일을 읽을 수 없습니다.")
        }
        do {
            let q = try DatabaseQueue(path: tmp.path, configuration: AppDatabase.configuration())
            defer { try? q.close() }
            let info = try q.read { db -> BackupInspection in
                let check = try String.fetchAll(db, sql: "PRAGMA integrity_check")
                guard check == ["ok"] else { throw StoreError.restoreRejected("백업 파일이 손상되었습니다(무결성 검사 실패).") }
                guard try db.tableExists("app_setting"),
                      try String.fetchOne(db, sql: "SELECT value FROM app_setting WHERE key = 'schema_family'") == AppPaths.appIdentifier else {
                    throw StoreError.restoreRejected("이 프로그램의 백업 파일이 아닙니다.")
                }
                let migrations = try AppDatabase.appliedMigrations(db)
                if let unknown = migrations.first(where: { !Schema.migrationIDs.contains($0) }) {
                    throw StoreError.restoreRejected("더 새로운 버전의 프로그램에서 만든 백업입니다(\(unknown)). 프로그램을 업데이트한 뒤 복원하세요.")
                }
                guard !migrations.isEmpty else { throw StoreError.restoreRejected("스키마 정보가 없는 파일입니다.") }
                return BackupInspection(
                    url: url, migrations: migrations,
                    customers: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM customer") ?? 0,
                    products: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM product") ?? 0,
                    licenses: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM license") ?? 0,
                    lastActivity: try String.fetchOne(db, sql: "SELECT MAX(at) FROM audit_log"))
            }
            // 이전 스키마 백업이면 임시 복사본에서 먼저 올려 본다(실패하면 복원 거부)
            try Schema.migrator.migrate(q)
            try q.close()
            return (info, tmp)
        } catch let e as StoreError {
            try? fm.removeItem(at: tmp)
            throw e
        } catch {
            try? fm.removeItem(at: tmp)
            throw StoreError.restoreRejected("SQLite 데이터베이스가 아니거나 열 수 없습니다.")
        }
    }

    /// 복원: 검증 → 현재 데이터 별도 백업 → 연결 닫기 → 교체 → 다시 열기. 실패하면 기존 데이터로 되돌린다.
    /// - Returns: 복원 전 현재 데이터 백업 위치
    @discardableResult
    public func restore(from url: URL) throws -> URL {
        guard let dbPath = database.path else { throw StoreError.restoreRejected("메모리 DB는 복원할 수 없습니다.") }
        let (info, validated) = try inspectCopy(url)
        let fm = FileManager.default
        defer { try? fm.removeItem(at: validated) }
        _ = info

        try fm.createDirectory(at: paths.backupsDir, withIntermediateDirectories: true)
        let safety = paths.backupsDir.appendingPathComponent("pre-restore-\(BackupNames.stamp(now())).sqlite")
        try Self.backup(from: database.dbQueue, to: safety)

        let current = URL(fileURLWithPath: dbPath)
        let old = current.deletingLastPathComponent().appendingPathComponent(current.lastPathComponent + ".restore-old")
        try? fm.removeItem(at: old)
        try database.close()
        do {
            try fm.moveItem(at: current, to: old)
            for suffix in ["-journal", "-wal", "-shm"] { try? fm.removeItem(atPath: dbPath + suffix) }
            try fm.copyItem(at: validated, to: current)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: current.path)
            try database.reopen()
            _ = try database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM license") }
        } catch {
            // 되돌리기
            try? database.close()
            try? fm.removeItem(at: current)
            try? fm.moveItem(at: old, to: current)
            try? database.reopen()
            throw StoreError.restoreRejected("교체 중 오류가 나서 기존 데이터로 되돌렸습니다: \(error.localizedDescription)")
        }
        try? fm.removeItem(at: old)
        try? database.write { db in
            try Audit.log(db, entity: "app", id: 0, action: "restore",
                          summary: "백업 복원: \(url.lastPathComponent) (복원 전 데이터: \(safety.lastPathComponent))", now: now())
        }
        return safety
    }
}
