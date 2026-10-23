import CryptoKit
import Foundation
import GRDB
import LicenseCore

/// 제품 입력값
public struct ProductInput: Equatable {
    public var code: String
    public var name: String
    public var description: String
    public var isActive: Bool
    public var v1ProductCode: String
    public var defaultEdition: String
    public var defaultMaxVersion: String
    /// 0이면 영구
    public var defaultTermMonths: Int
    public var generators: Set<GeneratorID>

    public init(code: String = "", name: String = "", description: String = "", isActive: Bool = true,
                v1ProductCode: String = "", defaultEdition: String = "standard", defaultMaxVersion: String = "",
                defaultTermMonths: Int = 0, generators: Set<GeneratorID> = [.lmsLicenseV1]) {
        self.code = code
        self.name = name
        self.description = description
        self.isActive = isActive
        self.v1ProductCode = v1ProductCode
        self.defaultEdition = defaultEdition
        self.defaultMaxVersion = defaultMaxVersion
        self.defaultTermMonths = defaultTermMonths
        self.generators = generators
    }

    public init(product: Product, generators: [ProductGenerator]) {
        self.init(code: product.code, name: product.name, description: product.description, isActive: product.isActive,
                  v1ProductCode: product.v1ProductCode ?? "", defaultEdition: product.defaultEdition,
                  defaultMaxVersion: product.defaultMaxVersion ?? "", defaultTermMonths: product.defaultTermMonths ?? 0,
                  generators: Set(generators.filter(\.isEnabled).compactMap(\.generator)))
    }
}

/// 제품 상세(제품 + 생성 방식 + 서명 키)
public struct ProductDetail: Equatable {
    public var product: Product
    public var generators: [ProductGenerator]
    public var keys: [SigningKey]
    public var licenseCount: Int

    public var enabledGenerators: [GeneratorID] {
        generators.filter(\.isEnabled).compactMap(\.generator).sorted { $0.rawValue < $1.rawValue }
    }
}

/// 서명 키 상태(키체인에 비밀키가 있는지)
public struct SigningKeyInfo: Identifiable, Equatable {
    public var key: SigningKey
    public var hasSecret: Bool
    public var id: Int64? { key.id }
}

public final class ProductService {
    let db: AppDatabase
    let keyStore: SecretKeyStore
    let now: Clock

    public init(db: AppDatabase, keyStore: SecretKeyStore, now: @escaping Clock = Date.init) {
        self.db = db
        self.keyStore = keyStore
        self.now = now
    }

    // MARK: 조회

    public func list(includeArchived: Bool = true) throws -> [Product] {
        try db.read { db in
            try Product.fetchAll(db, sql: "SELECT * FROM product \(includeArchived ? "" : "WHERE isArchived = 0") ORDER BY isArchived, name COLLATE NOCASE")
        }
    }

    public func detail(_ id: Int64) throws -> ProductDetail {
        try db.read { db in
            guard let p = try Product.fetchOne(db, key: id) else { throw StoreError.notFound("제품") }
            let gens = try ProductGenerator.fetchAll(db, sql: "SELECT * FROM product_generator WHERE productId = ? ORDER BY id", arguments: [id])
            let keys = try SigningKey.fetchAll(db, sql: "SELECT * FROM signing_key WHERE productId = ? ORDER BY status, id", arguments: [id])
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM license WHERE productId = ?", arguments: [id]) ?? 0
            return ProductDetail(product: p, generators: gens, keys: keys, licenseCount: count)
        }
    }

    public func keyInfos(productId: Int64) throws -> [SigningKeyInfo] {
        let keys = try detail(productId).keys
        return keys.map { SigningKeyInfo(key: $0, hasSecret: ((try? keyStore.load(account: $0.keychainAccount)) ?? nil) != nil) }
    }

    // MARK: 등록·수정

    func validate(_ input: ProductInput) throws -> ProductInput {
        var x = input
        x.code = x.code.trimmed
        x.name = x.name.trimmed
        x.v1ProductCode = x.v1ProductCode.trimmed
        x.defaultEdition = x.defaultEdition.trimmed
        x.defaultMaxVersion = x.defaultMaxVersion.trimmed
        if x.name.isEmpty { throw StoreError.invalid(field: "name", message: "제품명을 입력하세요.") }
        if x.code.isEmpty { throw StoreError.invalid(field: "code", message: "제품 코드를 입력하세요.") }
        if x.generators.isEmpty { throw StoreError.invalid(field: "generators", message: "라이선스 생성 방식을 하나 이상 고르세요(외부 라이선스만 관리하면 '수동 등록 전용').") }
        if x.generators.contains(.lmsLicenseV1) {
            if !TextRules.isV1ProductCode(x.v1ProductCode) {
                throw StoreError.invalid(field: "v1ProductCode", message: "공통 형식 제품 코드는 영문 대문자로 시작하고 대문자·숫자·_로 된 2~32자입니다. 예) REVIEWCUT")
            }
            if !TextRules.isEdition(x.defaultEdition) {
                throw StoreError.invalid(field: "defaultEdition", message: "기본 에디션은 영문 소문자로 시작하는 1~32자(소문자·숫자·_·-)입니다.")
            }
        }
        if !x.defaultMaxVersion.isEmpty && TextRules.parseSeries(x.defaultMaxVersion) == nil {
            throw StoreError.invalid(field: "defaultMaxVersion", message: "기본 사용 가능 최고 버전은 '주.부' 형식입니다(예: 1.0). 제한이 없으면 비워 두세요.")
        }
        if !(0...120).contains(x.defaultTermMonths) {
            throw StoreError.invalid(field: "defaultTermMonths", message: "기본 기간은 0(영구)~120개월입니다.")
        }
        return x
    }

    @discardableResult
    public func create(_ input: ProductInput) throws -> Product {
        let x = try validate(input)
        let ts = DBTime.string(now())
        do {
            return try db.write { db in
                if try Product.fetchOne(db, sql: "SELECT * FROM product WHERE code = ?", arguments: [x.code]) != nil {
                    throw StoreError.invalid(field: "code", message: "이미 있는 제품 코드입니다.")
                }
                if !x.v1ProductCode.isEmpty,
                   try Product.fetchOne(db, sql: "SELECT * FROM product WHERE v1ProductCode = ?", arguments: [x.v1ProductCode]) != nil {
                    throw StoreError.invalid(field: "v1ProductCode", message: "다른 제품이 이미 쓰는 공통 형식 제품 코드입니다.")
                }
                var p = Product(code: x.code, name: x.name, description: x.description, isActive: x.isActive,
                                v1ProductCode: x.v1ProductCode.nilIfEmpty, defaultEdition: x.defaultEdition.nilIfEmpty ?? "standard",
                                defaultMaxVersion: x.defaultMaxVersion.nilIfEmpty,
                                defaultTermMonths: x.defaultTermMonths == 0 ? nil : x.defaultTermMonths,
                                createdAt: ts, updatedAt: ts)
                try p.insert(db)
                try syncGenerators(db, productId: p.id!, enabled: x.generators, ts: ts)
                try Audit.log(db, entity: "product", id: p.id!, action: "create",
                              summary: "제품 등록: \(p.name) [\(p.code)] 생성 방식 \(x.generators.map(\.rawValue).sorted().joined(separator: ","))", now: now())
                return p
            }
        } catch { throw StoreError.from(error) }
    }

    /// 수정. 제품 코드·생성기 변경은 기존 발급 기록(스냅샷)을 바꾸지 않는다.
    @discardableResult
    public func update(_ id: Int64, _ input: ProductInput) throws -> Product {
        let x = try validate(input)
        let ts = DBTime.string(now())
        do {
            return try db.write { db in
                guard var p = try Product.fetchOne(db, key: id) else { throw StoreError.notFound("제품") }
                if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM product WHERE code = ? AND id <> ?", arguments: [x.code, id])! > 0 {
                    throw StoreError.invalid(field: "code", message: "이미 있는 제품 코드입니다.")
                }
                if !x.v1ProductCode.isEmpty,
                   try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM product WHERE v1ProductCode = ? AND id <> ?", arguments: [x.v1ProductCode, id])! > 0 {
                    throw StoreError.invalid(field: "v1ProductCode", message: "다른 제품이 이미 쓰는 공통 형식 제품 코드입니다.")
                }
                let before = "\(p.code)/\(p.v1ProductCode ?? "-")"
                p.code = x.code
                p.name = x.name
                p.description = x.description
                p.isActive = x.isActive
                p.v1ProductCode = x.v1ProductCode.nilIfEmpty
                p.defaultEdition = x.defaultEdition.nilIfEmpty ?? "standard"
                p.defaultMaxVersion = x.defaultMaxVersion.nilIfEmpty
                p.defaultTermMonths = x.defaultTermMonths == 0 ? nil : x.defaultTermMonths
                p.updatedAt = ts
                try p.update(db)
                try syncGenerators(db, productId: id, enabled: x.generators, ts: ts)
                try Audit.log(db, entity: "product", id: id, action: "update",
                              summary: "제품 수정: \(before) → \(p.code)/\(p.v1ProductCode ?? "-")", now: now())
                return p
            }
        } catch { throw StoreError.from(error) }
    }

    private func syncGenerators(_ db: Database, productId: Int64, enabled: Set<GeneratorID>, ts: String) throws {
        let existing = try ProductGenerator.fetchAll(db, sql: "SELECT * FROM product_generator WHERE productId = ?", arguments: [productId])
        for gid in GeneratorID.allCases {
            let version = GeneratorRegistry.generator(for: gid)?.version ?? "-"
            if var row = existing.first(where: { $0.generatorId == gid.rawValue }) {
                let on = enabled.contains(gid)
                if row.isEnabled != on || (on && row.generatorVersion != version) {
                    row.isEnabled = on
                    if on { row.generatorVersion = version }
                    row.updatedAt = ts
                    try row.update(db)
                }
            } else if enabled.contains(gid) {
                var row = ProductGenerator(productId: productId, generatorId: gid, generatorVersion: version, createdAt: ts, updatedAt: ts)
                try row.insert(db)
            }
        }
    }

    /// 보관/보관 해제. 라이선스가 있는 제품은 삭제하지 않고 보관한다.
    public func setArchived(_ id: Int64, _ archived: Bool) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE product SET isArchived = ?, updatedAt = ? WHERE id = ?", arguments: [archived, DBTime.string(now()), id])
            try Audit.log(db, entity: "product", id: id, action: archived ? "archive" : "unarchive", summary: archived ? "제품 보관" : "제품 보관 해제", now: now())
        }
    }

    /// 라이선스가 없는 제품만 삭제한다.
    public func delete(_ id: Int64) throws {
        do {
            try db.write { db in
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM license WHERE productId = ?", arguments: [id]) ?? 0
                guard count == 0 else { throw StoreError.conflict("라이선스 기록이 있는 제품은 삭제할 수 없습니다. 보관 처리하세요.") }
                let keys = try SigningKey.fetchAll(db, sql: "SELECT * FROM signing_key WHERE productId = ?", arguments: [id])
                guard keys.isEmpty else { throw StoreError.conflict("서명 키가 등록된 제품은 삭제할 수 없습니다. 보관 처리하세요.") }
                try db.execute(sql: "DELETE FROM product_generator WHERE productId = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM product WHERE id = ?", arguments: [id])
                try Audit.log(db, entity: "product", id: id, action: "delete", summary: "제품 삭제(라이선스 없음)", now: now())
            }
        } catch { throw StoreError.from(error) }
    }

    // MARK: 서명 키

    /// 새 키 쌍 만들기(새 제품용). 이미 판매한 제품에는 쓰지 않는다(기존 앱이 새 키를 모름).
    @discardableResult
    public func generateKey(productId: Int64, keyId: String) throws -> SigningKey {
        let kid = keyId.trimmed
        guard TextRules.isKeyId(kid) else {
            throw StoreError.invalid(field: "keyId", message: "key_id는 영문 소문자·숫자로 시작하고 소문자·숫자·.·_·-로 된 1~64자입니다. 예) myapp-2026")
        }
        let priv = Ed25519Keys.newPrivateKey()
        return try storeKey(productId: productId, keyId: kid, seed: priv.rawRepresentation,
                            publicRaw: priv.publicKey.rawRepresentation, origin: .generated)
    }

    /// 기존 비밀키 가져오기. 공개키가 기대값(고객 앱 공개키 또는 이미 등록한 공개키)과 다르면 거부한다.
    /// - Parameter expectedPublicKey: 고객 앱에 들어 있는 공개키(hex 또는 PEM). 비우면 알려진 값·등록된 값으로 대조.
    @discardableResult
    public func importKey(productId: Int64, keyId: String, fileContents: Data, expectedPublicKey: String?) throws -> SigningKey {
        let kid = keyId.trimmed
        guard TextRules.isKeyId(kid) else {
            throw StoreError.invalid(field: "keyId", message: "key_id 형식이 올바르지 않습니다.")
        }
        let detail = try self.detail(productId)
        let seed: Data
        do { seed = try Ed25519Keys.seed(fromFileContents: fileContents) } catch {
            throw StoreError.invalid(field: "file", message: (error as? LocalizedError)?.errorDescription ?? "비밀키를 읽을 수 없습니다.")
        }
        // 대조할 공개키: 직접 입력 > 이미 등록된 같은 key_id > 알려진 고객 앱 공개키
        var expected: Data?
        if let text = expectedPublicKey?.nilIfEmpty {
            guard let raw = Ed25519Keys.publicKeyRaw(fromText: text) else {
                throw StoreError.invalid(field: "expectedPublicKey", message: "확인용 공개키 형식을 읽을 수 없습니다(hex 64자리 또는 PEM).")
            }
            expected = raw
        }
        let existing = detail.keys.first { $0.keyId == kid }
        if let e = existing {
            if let x = expected, x != e.publicKeyRaw {
                throw StoreError.invalid(field: "expectedPublicKey", message: "입력한 확인용 공개키가 이미 등록된 key_id '\(kid)'의 공개키와 다릅니다.")
            }
            expected = e.publicKeyRaw
        }
        if expected == nil, let v1 = detail.product.v1ProductCode, let known = KnownCustomerAppKeys.entry(v1ProductCode: v1, keyId: kid) {
            expected = TextRules.dataFromHex(known.publicKeyHex)
        }
        guard let expectedRaw = expected else {
            throw StoreError.invalid(field: "expectedPublicKey", message: "고객 앱에 들어 있는 공개키를 '확인용 공개키'에 입력하세요. 같은 키인지 확인한 뒤에만 가져옵니다.")
        }
        let key: Curve25519.Signing.PrivateKey
        do { key = try Ed25519Keys.checkMatches(seed: seed, expectedPublicKeyRaw: expectedRaw) } catch {
            throw StoreError.invalid(field: "file", message: (error as? LocalizedError)?.errorDescription ?? "공개키가 다릅니다.")
        }
        if let e = existing {
            // 공개키만 등록되어 있던 항목(또는 다른 Mac에서 복원한 DB)에 비밀키를 채운다
            if ((try? keyStore.load(account: e.keychainAccount)) ?? nil) != nil {
                throw StoreError.conflict("이 key_id의 비밀키가 이미 키체인에 있습니다.")
            }
            try keyStore.save(seed: key.rawRepresentation, account: e.keychainAccount)
            try db.write { db in
                try db.execute(sql: "UPDATE signing_key SET origin = 'imported', updatedAt = ? WHERE id = ?",
                               arguments: [DBTime.string(now()), e.id])
                try Audit.log(db, entity: "signing_key", id: e.id!, action: "import-secret",
                              summary: "비밀키 가져옴: \(kid) (공개키 일치 확인)", now: now())
            }
            return try db.read { db in try SigningKey.fetchOne(db, key: e.id!)! }
        }
        return try storeKey(productId: productId, keyId: kid, seed: key.rawRepresentation,
                            publicRaw: key.publicKey.rawRepresentation, origin: .imported)
    }

    /// 고객 앱 공개키만 먼저 등록(비밀키는 나중에 가져옴). 수동 등록 파일 검증에도 쓰인다.
    @discardableResult
    public func registerExpectedPublicKey(productId: Int64, keyId: String, publicKey: String) throws -> SigningKey {
        let kid = keyId.trimmed
        guard TextRules.isKeyId(kid) else { throw StoreError.invalid(field: "keyId", message: "key_id 형식이 올바르지 않습니다.") }
        guard let raw = Ed25519Keys.publicKeyRaw(fromText: publicKey) else {
            throw StoreError.invalid(field: "publicKey", message: "공개키 형식을 읽을 수 없습니다(hex 64자리 또는 PEM).")
        }
        let ts = DBTime.string(now())
        do {
            return try db.write { db in
                var k = SigningKey(productId: productId, keyId: kid, publicKeyHex: TextRules.hex(raw), origin: .expected,
                                   createdAt: ts, updatedAt: ts)
                try k.insert(db)
                try Audit.log(db, entity: "signing_key", id: k.id!, action: "register-public",
                              summary: "공개키 등록: \(kid)", now: now())
                return k
            }
        } catch { throw StoreError.from(error) }
    }

    private func storeKey(productId: Int64, keyId: String, seed: Data, publicRaw: Data, origin: SigningKeyOrigin) throws -> SigningKey {
        let ts = DBTime.string(now())
        let account = UUID().uuidString
        // 키체인 먼저 저장 → DB 저장 실패 시 키체인 항목 제거
        try keyStore.save(seed: seed, account: account)
        do {
            return try db.write { db in
                if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM signing_key WHERE productId = ? AND keyId = ?", arguments: [productId, keyId])! > 0 {
                    throw StoreError.invalid(field: "keyId", message: "이 제품에 같은 key_id가 이미 있습니다.")
                }
                var k = SigningKey(productId: productId, keyId: keyId, publicKeyHex: TextRules.hex(publicRaw), origin: origin,
                                   keychainAccount: account, createdAt: ts, updatedAt: ts)
                try k.insert(db)
                try Audit.log(db, entity: "signing_key", id: k.id!, action: origin == .generated ? "generate" : "import",
                              summary: "서명 키 \(origin == .generated ? "생성" : "가져옴"): \(keyId)", now: now())
                return k
            }
        } catch {
            try? keyStore.delete(account: account)
            throw StoreError.from(error)
        }
    }

    public func setKeyStatus(_ keyRowId: Int64, _ status: SigningKeyStatus) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE signing_key SET status = ?, updatedAt = ? WHERE id = ?",
                           arguments: [status.rawValue, DBTime.string(now()), keyRowId])
            try Audit.log(db, entity: "signing_key", id: keyRowId, action: "status", summary: "서명 키 상태: \(status.displayName)", now: now())
        }
    }

    /// 비밀키 내보내기(오프라인 백업용). 사용자가 고른 위치에 권한 600 PKCS#8 PEM 파일로만 저장한다.
    public func exportPrivateKey(keyRowId: Int64, to url: URL) throws {
        let key = try db.read { db in try SigningKey.fetchOne(db, key: keyRowId) }
        guard let key, let seed = try keyStore.load(account: key.keychainAccount) else {
            throw StoreError.keyMissing("이 Mac의 키체인에 비밀키가 없습니다.")
        }
        let pem = Data(Ed25519Keys.pkcs8PEM(seed: seed).utf8)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw StoreError.io("파일을 만들 수 없습니다.")
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: pem)
        try handle.close()
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try db.write { db in
            try Audit.log(db, entity: "signing_key", id: keyRowId, action: "export-secret",
                          summary: "비밀키 내보냄(오프라인 백업): \(key.keyId)", now: now())
        }
    }

    /// 발급용 키: 제품의 사용 중 키 중 키체인에 비밀키가 있는 첫 번째
    func signingMaterial(productId: Int64) throws -> (SigningMaterial, SigningKey) {
        let keys = try db.read { db in
            try SigningKey.fetchAll(db, sql: "SELECT * FROM signing_key WHERE productId = ? AND status = 'active' ORDER BY id DESC", arguments: [productId])
        }
        guard !keys.isEmpty else {
            throw StoreError.keyMissing("이 제품에 서명 키가 없습니다. 제품 화면에서 서명 키를 가져오거나 만드세요.")
        }
        for k in keys {
            if let seed = try keyStore.load(account: k.keychainAccount) {
                let priv = try Ed25519Keys.privateKey(seed: seed)
                guard priv.publicKey.rawRepresentation == k.publicKeyRaw else {
                    throw StoreError.keyMissing("키체인의 비밀키가 등록된 공개키(\(k.keyId))와 다릅니다. 키를 다시 가져오세요.")
                }
                return (SigningMaterial(keyId: k.keyId, privateKey: priv), k)
            }
        }
        throw StoreError.keyMissing("이 Mac의 키체인에 서명 비밀키가 없습니다(다른 Mac에서 복원했다면 제품 화면에서 키를 다시 가져오세요). 공개키 \(keys.map(\.keyId).joined(separator: ", "))")
    }

    /// 수동 등록 파일 검증용 공개키(보관 키 포함)
    func publicKeys(productId: Int64?) throws -> [PublicKeyRef] {
        try db.read { db in
            if let productId {
                return try SigningKey.fetchAll(db, sql: "SELECT * FROM signing_key WHERE productId = ?", arguments: [productId]).map(\.publicKeyRef)
            }
            return try SigningKey.fetchAll(db).map(\.publicKeyRef)
        }
    }

    // MARK: 기존 제품 기본 설정

    /// 이미 판매한 ReviewCut·RentalDesk 제품 설정을 추가한다(고객 앱 공개키 등록 포함, 비밀키는 따로 가져와야 함).
    public func addKnownProducts() throws -> [Product] {
        var created: [Product] = []
        let existing = try list()
        let presets: [(ProductInput, KnownCustomerAppKeys.Entry)] = [
            (ProductInput(code: "REVIEWCUT", name: "ReviewCut", description: "리뷰 컷 편집 프로그램",
                          v1ProductCode: "REVIEWCUT", defaultEdition: "full", defaultMaxVersion: "",
                          generators: [.lmsLicenseV1, .reviewcutLegacy]), KnownCustomerAppKeys.reviewCut),
            (ProductInput(code: "RENTALDESK", name: "RentalDesk", description: "렌탈 관리 프로그램",
                          v1ProductCode: "RENTALDESK", defaultEdition: "standard", defaultMaxVersion: "1.0",
                          generators: [.lmsLicenseV1, .rentaldeskLegacy]), KnownCustomerAppKeys.rentalDesk),
        ]
        for (input, known) in presets {
            if existing.contains(where: { $0.code == input.code || $0.v1ProductCode == input.v1ProductCode }) { continue }
            let p = try create(input)
            try registerExpectedPublicKey(productId: p.id!, keyId: known.keyId, publicKey: known.publicKeyHex)
            created.append(p)
        }
        return created
    }
}
