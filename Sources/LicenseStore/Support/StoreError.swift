import Foundation
import GRDB
import LicenseCore

/// 사용자에게 보여줄 수 있는 오류. 비밀키·라이선스 원문을 메시지에 넣지 않는다.
public enum StoreError: Error, LocalizedError, Equatable {
    /// 입력 오류(필드 이름, 문구)
    case invalid(field: String?, message: String)
    case notFound(String)
    case conflict(String)
    case duplicatePC(ownerCustomerId: Int64, ownerName: String)
    case overlap([String])
    case keyMissing(String)
    case generation([ValidationIssue])
    case selfVerificationFailed(String)
    case incompatibleDatabase(String)
    case restoreRejected(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(_, let m): return m
        case .notFound(let what): return "\(what)을(를) 찾을 수 없습니다."
        case .conflict(let m): return m
        case .duplicatePC(_, let owner):
            return "이미 등록된 PC 번호입니다. 소유 고객: \(owner). 다른 고객에게 임의로 다시 배정하지 않습니다."
        case .overlap(let nos):
            return "같은 제품·PC에 유효기간이 겹치는 발급됨 라이선스가 있습니다: \(nos.joined(separator: ", ")). 기존 라이선스를 대체 처리하거나 기간을 조정하세요."
        case .keyMissing(let m): return m
        case .generation(let issues): return issues.map(\.message).joined(separator: "\n")
        case .selfVerificationFailed(let m): return "발급 직후 검증에 실패하여 저장하지 않았습니다: \(m)"
        case .incompatibleDatabase(let m): return m
        case .restoreRejected(let m): return "복원하지 않았습니다: \(m)"
        case .io(let m): return m
        }
    }

    /// 필드 이름(입력 오류를 필드 가까이에 표시하기 위함)
    public var field: String? {
        if case .invalid(let f, _) = self { return f }
        return nil
    }

    /// SQLite 제약 오류를 안전한 문구로 바꾼다
    static func from(_ error: Error) -> Error {
        guard let db = error as? DatabaseError else { return error }
        let msg = db.message ?? ""
        if msg.contains("LMS: license customer must match PC owner") {
            return StoreError.conflict("라이선스 고객과 PC 소유 고객이 다릅니다.")
        }
        if msg.contains("LMS: issued license content is immutable") {
            return StoreError.conflict("발급한 라이선스의 제품·PC·내용·기간은 바꿀 수 없습니다. 새로 발급하세요.")
        }
        if msg.contains("LMS: only issued licenses can change status") {
            return StoreError.conflict("이미 취소되었거나 대체된 라이선스입니다.")
        }
        if msg.contains("LMS: PC number with licenses is immutable") {
            return StoreError.conflict("라이선스가 발급된 PC의 번호는 바꿀 수 없습니다. 새 PC로 등록하고 재발급하세요.")
        }
        if db.extendedResultCode == .SQLITE_CONSTRAINT_FOREIGNKEY {
            return StoreError.conflict("연결된 기록이 있어 처리할 수 없습니다(이력이 있는 항목은 삭제하지 않고 보관하세요).")
        }
        if db.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
            return StoreError.conflict("이미 같은 값이 등록되어 있습니다.")
        }
        return StoreError.io("데이터베이스 오류: \(db.resultCode)")
    }
}

/// 현재 시각 공급(테스트에서 고정)
public typealias Clock = () -> Date

/// 감사 기록. 발급 데이터와 같은 트랜잭션에서 쓴다.
enum Audit {
    static func log(_ db: Database, entity: String, id: Int64, action: String, summary: String, reason: String = "", now: Date) throws {
        var entry = AuditLog(entityType: entity, entityId: id, action: action, at: DBTime.string(now),
                             summary: summary, reason: reason)
        try entry.insert(db)
    }
}

/// 문자열 정리
extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { trimmed.isEmpty ? nil : trimmed }
}

/// 로그·감사 기록용 마스킹
public enum Mask {
    /// PC 번호: 앞 5자만 보이고 나머지는 *
    public static func pc(_ s: String) -> String {
        let chars = Array(s)
        guard chars.count > 5 else { return String(repeating: "*", count: chars.count) }
        return String(chars.prefix(5)) + String(repeating: "*", count: min(chars.count - 5, 8))
    }

    /// 연락처·이메일 등: 앞 2자만
    public static func text(_ s: String) -> String {
        let chars = Array(s)
        guard chars.count > 2 else { return String(repeating: "*", count: chars.count) }
        return String(chars.prefix(2)) + "***"
    }
}
