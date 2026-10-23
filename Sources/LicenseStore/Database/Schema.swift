import GRDB

/// 스키마 마이그레이션. 식별자는 한 번 배포하면 바꾸지 않는다.
/// 백업 복원 시 백업 파일의 마이그레이션 목록이 이 목록에 포함되어야 한다(더 새로운 앱의 백업은 거부).
enum Schema {
    static let migrationIDs = ["v1-initial"]

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1-initial") { db in
            try db.execute(sql: v1)
        }
        return m
    }

    /// 시각 열은 모두 UTC `YYYY-MM-DDTHH:MM:SSZ` 문자열(문자열 정렬 = 시간 순서).
    static let v1 = """
    CREATE TABLE product (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        code TEXT NOT NULL UNIQUE CHECK (length(trim(code)) > 0),
        name TEXT NOT NULL CHECK (length(trim(name)) > 0),
        description TEXT NOT NULL DEFAULT '',
        isActive INTEGER NOT NULL DEFAULT 1 CHECK (isActive IN (0, 1)),
        isArchived INTEGER NOT NULL DEFAULT 0 CHECK (isArchived IN (0, 1)),
        v1ProductCode TEXT UNIQUE,
        defaultEdition TEXT NOT NULL DEFAULT 'standard',
        defaultMaxVersion TEXT,
        defaultTermMonths INTEGER CHECK (defaultTermMonths IS NULL OR defaultTermMonths BETWEEN 1 AND 120),
        settingsJSON TEXT NOT NULL DEFAULT '{}',
        createdAt TEXT NOT NULL,
        updatedAt TEXT NOT NULL
    );

    CREATE TABLE product_generator (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        productId INTEGER NOT NULL REFERENCES product(id),
        generatorId TEXT NOT NULL CHECK (generatorId IN ('lms-license-v1', 'reviewcut-legacy', 'rentaldesk-legacy', 'manual')),
        generatorVersion TEXT NOT NULL,
        isEnabled INTEGER NOT NULL DEFAULT 1 CHECK (isEnabled IN (0, 1)),
        createdAt TEXT NOT NULL,
        updatedAt TEXT NOT NULL,
        UNIQUE (productId, generatorId)
    );

    -- 서명 키: 공개키와 key_id만 저장한다. 비밀키는 macOS 키체인(keychainAccount 항목)에만 있다.
    CREATE TABLE signing_key (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        productId INTEGER NOT NULL REFERENCES product(id),
        keyId TEXT NOT NULL,
        publicKeyHex TEXT NOT NULL CHECK (length(publicKeyHex) = 64),
        status TEXT NOT NULL CHECK (status IN ('active', 'archived')),
        origin TEXT NOT NULL CHECK (origin IN ('generated', 'imported', 'expected')),
        keychainAccount TEXT NOT NULL UNIQUE,
        note TEXT NOT NULL DEFAULT '',
        createdAt TEXT NOT NULL,
        updatedAt TEXT NOT NULL,
        UNIQUE (productId, keyId)
    );

    CREATE TABLE customer (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL CHECK (length(trim(name)) > 0),
        contactPerson TEXT NOT NULL DEFAULT '',
        phone TEXT NOT NULL DEFAULT '',
        email TEXT NOT NULL DEFAULT '',
        memo TEXT NOT NULL DEFAULT '',
        isArchived INTEGER NOT NULL DEFAULT 0 CHECK (isArchived IN (0, 1)),
        createdAt TEXT NOT NULL,
        updatedAt TEXT NOT NULL
    );

    CREATE TABLE customer_pc (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        customerId INTEGER NOT NULL REFERENCES customer(id),
        scheme TEXT NOT NULL CHECK (scheme IN ('lms-pc-v1', 'rentaldesk-machine-v0', 'reviewcut-install-id', 'manual')),
        numberRaw TEXT NOT NULL,
        numberNormalized TEXT NOT NULL CHECK (length(numberNormalized) > 0),
        alias TEXT NOT NULL DEFAULT '',
        memo TEXT NOT NULL DEFAULT '',
        createdAt TEXT NOT NULL,
        updatedAt TEXT NOT NULL,
        UNIQUE (scheme, numberNormalized)
    );
    CREATE INDEX customer_pc_customer ON customer_pc(customerId);

    -- 같은 실제 PC의 다른 체계 번호(수동 연결)
    CREATE TABLE pc_link (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        pcAId INTEGER NOT NULL REFERENCES customer_pc(id),
        pcBId INTEGER NOT NULL REFERENCES customer_pc(id),
        memo TEXT NOT NULL DEFAULT '',
        createdAt TEXT NOT NULL,
        CHECK (pcAId < pcBId),
        UNIQUE (pcAId, pcBId)
    );

    CREATE TABLE license (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        managementNo TEXT NOT NULL UNIQUE,
        customerId INTEGER NOT NULL REFERENCES customer(id),
        productId INTEGER NOT NULL REFERENCES product(id),
        pcId INTEGER NOT NULL REFERENCES customer_pc(id),
        status TEXT NOT NULL CHECK (status IN ('issued', 'cancelled', 'superseded')),
        issueMethod TEXT NOT NULL CHECK (issueMethod IN ('auto', 'manual', 'import')),
        verification TEXT NOT NULL CHECK (verification IN ('verified', 'unverified')),
        verificationDetail TEXT NOT NULL DEFAULT '',
        generatorId TEXT NOT NULL,
        generatorVersion TEXT NOT NULL DEFAULT '',
        keyId TEXT,
        fileLicenseId TEXT UNIQUE,
        startsAt TEXT NOT NULL,
        expiresAt TEXT,
        issuedAt TEXT NOT NULL,
        licenseFile BLOB,
        licenseFileName TEXT,
        signedPayload TEXT,
        conditionsJSON TEXT NOT NULL DEFAULT '{}',
        memo TEXT NOT NULL DEFAULT '',
        externalRef TEXT,
        importSource TEXT,
        importKey TEXT UNIQUE,
        requestToken TEXT UNIQUE,
        statusReason TEXT,
        statusChangedAt TEXT,
        createdAt TEXT NOT NULL,
        updatedAt TEXT NOT NULL,
        CHECK (expiresAt IS NULL OR expiresAt > startsAt)
    );
    CREATE INDEX license_product_pc ON license(productId, pcId, status);
    CREATE INDEX license_customer ON license(customerId);
    CREATE INDEX license_pc ON license(pcId);
    CREATE INDEX license_expires ON license(status, expiresAt);

    -- 갱신·교체 연결. 새 라이선스는 항상 나중에 만들어지므로 from < to 이고, 순환이 생길 수 없다.
    CREATE TABLE license_relation (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        fromLicenseId INTEGER NOT NULL REFERENCES license(id),
        toLicenseId INTEGER NOT NULL REFERENCES license(id),
        kind TEXT NOT NULL CHECK (kind IN ('renewal', 'replacement')),
        reason TEXT NOT NULL DEFAULT '',
        createdAt TEXT NOT NULL,
        CHECK (fromLicenseId < toLicenseId),
        UNIQUE (toLicenseId)
    );
    CREATE INDEX license_relation_from ON license_relation(fromLicenseId);

    -- 감사 기록: 비밀키·라이선스 원문 전체는 넣지 않는다. 로컬 DB이므로 위변조 방지 증거는 아니다.
    CREATE TABLE audit_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        entityType TEXT NOT NULL,
        entityId INTEGER NOT NULL,
        action TEXT NOT NULL,
        at TEXT NOT NULL,
        summary TEXT NOT NULL,
        reason TEXT NOT NULL DEFAULT ''
    );
    CREATE INDEX audit_log_entity ON audit_log(entityType, entityId);

    CREATE TABLE app_setting (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );

    -- 라이선스 고객과 PC 소유 고객이 같아야 한다
    CREATE TRIGGER license_pc_customer_insert BEFORE INSERT ON license
    WHEN (SELECT customerId FROM customer_pc WHERE id = NEW.pcId) IS NOT NEW.customerId
    BEGIN
        SELECT RAISE(ABORT, 'LMS: license customer must match PC owner');
    END;

    -- 발급한 라이선스의 제품·PC·내용·기간은 덮어쓰지 않는다
    CREATE TRIGGER license_immutable BEFORE UPDATE ON license
    WHEN NEW.managementNo IS NOT OLD.managementNo OR NEW.customerId IS NOT OLD.customerId
      OR NEW.productId IS NOT OLD.productId OR NEW.pcId IS NOT OLD.pcId
      OR NEW.startsAt IS NOT OLD.startsAt OR NEW.expiresAt IS NOT OLD.expiresAt OR NEW.issuedAt IS NOT OLD.issuedAt
      OR NEW.licenseFile IS NOT OLD.licenseFile OR NEW.signedPayload IS NOT OLD.signedPayload
      OR NEW.conditionsJSON IS NOT OLD.conditionsJSON OR NEW.fileLicenseId IS NOT OLD.fileLicenseId
      OR NEW.generatorId IS NOT OLD.generatorId OR NEW.generatorVersion IS NOT OLD.generatorVersion
      OR NEW.keyId IS NOT OLD.keyId OR NEW.issueMethod IS NOT OLD.issueMethod OR NEW.verification IS NOT OLD.verification
    BEGIN
        SELECT RAISE(ABORT, 'LMS: issued license content is immutable');
    END;

    -- 처리 상태는 '발급됨'에서만 바꿀 수 있다(취소·대체는 되돌리지 않음)
    CREATE TRIGGER license_status_transition BEFORE UPDATE OF status ON license
    WHEN NEW.status IS NOT OLD.status AND OLD.status <> 'issued'
    BEGIN
        SELECT RAISE(ABORT, 'LMS: only issued licenses can change status');
    END;

    CREATE TRIGGER license_no_delete BEFORE DELETE ON license
    BEGIN
        SELECT RAISE(ABORT, 'LMS: licenses are never deleted');
    END;

    -- 라이선스가 있는 PC의 번호·체계·고객은 바꾸지 않는다
    CREATE TRIGGER customer_pc_immutable BEFORE UPDATE ON customer_pc
    WHEN (NEW.scheme IS NOT OLD.scheme OR NEW.numberRaw IS NOT OLD.numberRaw
          OR NEW.numberNormalized IS NOT OLD.numberNormalized OR NEW.customerId IS NOT OLD.customerId)
      AND EXISTS (SELECT 1 FROM license WHERE pcId = OLD.id)
    BEGIN
        SELECT RAISE(ABORT, 'LMS: PC number with licenses is immutable');
    END;

    CREATE TRIGGER audit_log_no_update BEFORE UPDATE ON audit_log
    BEGIN
        SELECT RAISE(ABORT, 'LMS: audit log is append-only');
    END;

    CREATE TRIGGER audit_log_no_delete BEFORE DELETE ON audit_log
    BEGIN
        SELECT RAISE(ABORT, 'LMS: audit log is append-only');
    END;

    INSERT INTO app_setting(key, value) VALUES ('schema_family', 'kr.lms.LicenseManager');
    """
}
