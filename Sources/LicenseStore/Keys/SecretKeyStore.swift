import Foundation
import Security

/// 서명 비밀키(32바이트 seed) 저장소. 실제 앱은 macOS 키체인만 쓴다.
/// 비밀키는 DB·로그·일반 백업·설정 파일에 넣지 않는다.
public protocol SecretKeyStore: AnyObject {
    func save(seed: Data, account: String) throws
    func load(account: String) throws -> Data?
    func delete(account: String) throws
}

public enum KeychainError: Error, LocalizedError {
    case status(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .status(let s):
            let text = (SecCopyErrorMessageString(s, nil) as String?) ?? "알 수 없는 오류"
            return "키체인 오류(\(s)): \(text)"
        }
    }
}

/// macOS 키체인 저장소.
/// - 접근 조건: 기기 잠금 해제 시, 이 기기에서만(`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), 동기화 안 함.
/// - 데이터 보호 키체인을 우선 사용하고, 서명 자격(entitlement)이 없는 빌드(임시 서명 등)에서는
///   로그인 키체인에 저장한다. 로그인 키체인 항목은 기본적으로 저장한 앱만 묻지 않고 읽을 수 있다
///   (다시 빌드해 서명이 바뀌면 macOS가 접근 허용 여부를 물을 수 있음).
public final class KeychainKeyStore: SecretKeyStore {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    private func baseQuery(account: String, dataProtection: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    public func save(seed: Data, account: String) throws {
        precondition(seed.count == 32, "seed는 32바이트")
        for dp in [true, false] {
            var q = baseQuery(account: account, dataProtection: dp)
            q[kSecValueData as String] = seed
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            q[kSecAttrLabel as String] = "라이선스 관리 서명 키"
            let status = SecItemAdd(q as CFDictionary, nil)
            if status == errSecSuccess { return }
            if status == errSecDuplicateItem {
                throw KeychainError.status(status) // 같은 항목을 덮어쓰지 않는다(계정은 키마다 새 UUID)
            }
            if dp && status == errSecMissingEntitlement { continue }
            throw KeychainError.status(status)
        }
    }

    public func load(account: String) throws -> Data? {
        for dp in [true, false] {
            var q = baseQuery(account: account, dataProtection: dp)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data { return data }
            if status == errSecItemNotFound || (dp && status == errSecMissingEntitlement) { continue }
            throw KeychainError.status(status)
        }
        return nil
    }

    public func delete(account: String) throws {
        for dp in [true, false] {
            let status = SecItemDelete(baseQuery(account: account, dataProtection: dp) as CFDictionary)
            if status == errSecSuccess || status == errSecItemNotFound { continue }
            if dp && status == errSecMissingEntitlement { continue }
            throw KeychainError.status(status)
        }
    }
}

/// 메모리 저장소(테스트·데모 전용). 앱 종료 시 사라진다.
public final class InMemoryKeyStore: SecretKeyStore {
    private var items: [String: Data] = [:]
    public init() {}
    public func save(seed: Data, account: String) throws { items[account] = seed }
    public func load(account: String) throws -> Data? { items[account] }
    public func delete(account: String) throws { items[account] = nil }
}
