import Foundation
import GRDB
import LicenseCore

/// SQLite 데이터베이스 연결. 단일 연결(DatabaseQueue)로 쓰기를 직렬화한다.
public final class AppDatabase {
    public private(set) var dbQueue: DatabaseQueue
    /// nil이면 메모리 DB(테스트)
    public let path: String?

    static func configuration() -> Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.label = "LicenseManager"
        config.prepareDatabase { db in
            // 기본 DELETE 저널: 백업·복원 시 DB 파일 하나만 다루면 된다.
            try db.execute(sql: "PRAGMA journal_mode = DELETE")
            try db.execute(sql: "PRAGMA secure_delete = ON")
        }
        return config
    }

    /// 파일 DB를 열고 마이그레이션한다. 적용할 마이그레이션이 있고 기존 데이터가 있으면 먼저 백업한다.
    /// - Parameter preMigrationBackupDir: 업그레이드 전 백업을 둘 폴더(nil이면 백업하지 않음)
    public init(path: String, preMigrationBackupDir: URL? = nil, now: Date = Date()) throws {
        self.path = path
        self.dbQueue = try DatabaseQueue(path: path, configuration: Self.configuration())
        try migrateWithBackup(backupDir: preMigrationBackupDir, now: now)
    }

    private init(queue: DatabaseQueue) {
        self.path = nil
        self.dbQueue = queue
    }

    /// 테스트용 메모리 DB
    public static func inMemory() throws -> AppDatabase {
        let db = AppDatabase(queue: try DatabaseQueue(configuration: configuration()))
        try Schema.migrator.migrate(db.dbQueue)
        return db
    }

    private func migrateWithBackup(backupDir: URL?, now: Date) throws {
        let migrator = Schema.migrator
        let (applied, completed) = try dbQueue.read { db -> ([String], Bool) in
            let applied = try Self.appliedMigrations(db)
            return (applied, try migrator.hasCompletedMigrations(db))
        }
        if let unknown = applied.first(where: { !Schema.migrationIDs.contains($0) }) {
            throw StoreError.incompatibleDatabase("이 데이터베이스는 더 새로운 버전의 프로그램에서 만들어졌습니다(\(unknown)). 프로그램을 업데이트하세요.")
        }
        if !completed, !applied.isEmpty, let dir = backupDir {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = BackupNames.stamp(now)
            let target = dir.appendingPathComponent("pre-migration-\(stamp).sqlite")
            try BackupService.backup(from: dbQueue, to: target)
        }
        try migrator.migrate(dbQueue)
    }

    static func appliedMigrations(_ db: Database) throws -> [String] {
        guard try db.tableExists("grdb_migrations") else { return [] }
        return try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
    }

    public func read<T>(_ block: (Database) throws -> T) throws -> T {
        try dbQueue.read(block)
    }

    /// 하나의 트랜잭션. 블록에서 오류가 나면 전체를 되돌린다.
    public func write<T>(_ block: (Database) throws -> T) throws -> T {
        try dbQueue.write(block)
    }

    public func close() throws {
        try dbQueue.close()
    }

    /// 복원 후 같은 경로로 다시 연다
    func reopen() throws {
        guard let path else { return }
        dbQueue = try DatabaseQueue(path: path, configuration: Self.configuration())
        try Schema.migrator.migrate(dbQueue)
    }
}

public enum BackupNames {
    public static func stamp(_ date: Date) -> String {
        // 서울 기준 YYYYMMDD-HHMMSS
        let s = LicenseTimeBridge.seoulCompact(date)
        return s
    }
}

enum LicenseTimeBridge {
    static func seoulCompact(_ date: Date) -> String {
        let text = LicenseTime.seoulDisplay(date, seconds: true) // YYYY-MM-DD HH:MM:SS
        return text.replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "-")
    }
}
