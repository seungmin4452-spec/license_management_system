import Foundation
import GRDB

/// 데이터 위치: 앱 번들 안이 아니라 현재 사용자의 `~/Library/Application Support/<앱 식별자>/`.
/// 관리자 권한이 필요 없다.
public struct AppPaths {
    public static let appIdentifier = "kr.lms.LicenseManager"

    public let root: URL
    public var databaseURL: URL { root.appendingPathComponent("LicenseManager.sqlite") }
    public var backupsDir: URL { root.appendingPathComponent("Backups", isDirectory: true) }
    public var logsDir: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    public var lockURL: URL { root.appendingPathComponent(".instance.lock") }

    public init(root: URL) {
        self.root = root
    }

    /// 운영 데이터 위치
    public static func standard() throws -> AppPaths {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let paths = AppPaths(root: base.appendingPathComponent(appIdentifier, isDirectory: true))
        try paths.createDirectories()
        return paths
    }

    /// 데모 데이터 위치(운영 데이터와 분리)
    public func demo() throws -> AppPaths {
        let paths = AppPaths(root: root.appendingPathComponent("Demo", isDirectory: true))
        try paths.createDirectories()
        return paths
    }

    public func createDirectories() throws {
        let fm = FileManager.default
        for dir in [root, backupsDir, logsDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
}

/// 같은 데이터베이스를 쓰는 앱을 하나만 실행(MVP). flock 기반, 프로세스가 끝나면 자동 해제.
public final class SingleInstanceLock {
    private var fd: Int32 = -1

    public init() {}

    /// 잠금 성공 여부
    public func acquire(at url: URL) -> Bool {
        fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return false }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            fd = -1
            return false
        }
        return true
    }

    public func release() {
        if fd >= 0 {
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }
    }

    deinit { release() }
}

/// 비밀정보가 아닌 환경설정(app_setting)
public final class SettingsStore {
    let db: AppDatabase

    public init(db: AppDatabase) {
        self.db = db
    }

    public func string(_ key: String) -> String? {
        try? db.read { db in try String.fetchOne(db, sql: "SELECT value FROM app_setting WHERE key = ?", arguments: [key]) }
    }

    public func set(_ key: String, _ value: String) throws {
        try db.write { db in
            try db.execute(sql: "INSERT INTO app_setting(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [key, value])
        }
    }

    /// 자동 백업 보존 개수(기본 30)
    public var autoBackupKeep: Int {
        get { string("auto_backup_keep").flatMap(Int.init) ?? 30 }
    }

    public func setAutoBackupKeep(_ n: Int) throws {
        try set("auto_backup_keep", String(max(1, min(n, 1000))))
    }

    /// 종료 시 자동 백업(기본 켬)
    public var autoBackupOnQuit: Bool {
        string("auto_backup_on_quit").map { $0 == "1" } ?? true
    }

    public func setAutoBackupOnQuit(_ on: Bool) throws {
        try set("auto_backup_on_quit", on ? "1" : "0")
    }
}

/// 오류 추적용 최소 로그. PC 번호·연락처 등은 호출하는 쪽에서 `Mask`로 가린다. 크기·개수 제한.
public final class AppLogger {
    public static var shared: AppLogger?
    let dir: URL
    let maxBytes = 512 * 1024
    let keepFiles = 3
    private let queue = DispatchQueue(label: "AppLogger")

    public init(dir: URL) {
        self.dir = dir
    }

    var current: URL { dir.appendingPathComponent("app.log") }

    public func log(_ level: String, _ message: String) {
        let line = "\(LicenseTimeBridge.seoulCompact(Date())) [\(level)] \(message)\n"
        queue.async { [self] in
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: current.path))?[.size] as? Int, size > maxBytes { rotate() }
            if !fm.fileExists(atPath: current.path) {
                fm.createFile(atPath: current.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            if let h = try? FileHandle(forWritingTo: current) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: Data(line.utf8))
                try? h.close()
            }
        }
    }

    private func rotate() {
        let fm = FileManager.default
        for i in stride(from: keepFiles - 1, through: 1, by: -1) {
            let src = dir.appendingPathComponent("app.\(i).log")
            let dst = dir.appendingPathComponent("app.\(i + 1).log")
            try? fm.removeItem(at: dst)
            try? fm.moveItem(at: src, to: dst)
        }
        try? fm.removeItem(at: dir.appendingPathComponent("app.\(keepFiles).log"))
        try? fm.moveItem(at: current, to: dir.appendingPathComponent("app.1.log"))
    }
}
