import CryptoKit
import Foundation

/// PC 번호 체계. 같은 실제 PC라도 체계가 다르면 별도 PC 기록이 된다.
public enum PcScheme: String, CaseIterable, Codable, Sendable, Identifiable {
    /// 공통 PC 번호 25자 `XXXXX-XXXXX-XXXXX-XXXXX-XXXXX` (모든 공통 형식 제품에서 같은 번호)
    case lmsPcV1 = "lms-pc-v1"
    /// RentalDesk 1.0.0 기기 코드 20자 `XXXX-XXXX-XXXX-XXXX-XXXX`
    case rentaldeskMachineV0 = "rentaldesk-machine-v0"
    /// ReviewCut 0.1.0 설치 ID `VRN-XXXX-XXXX-XXXX` (정규화 없음)
    case reviewcutInstallId = "reviewcut-install-id"
    /// 그 밖의 제품 (정규화 없음)
    case manual = "manual"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .lmsPcV1: return "공통 PC 번호 (25자)"
        case .rentaldeskMachineV0: return "RentalDesk 1.0 기기 코드 (20자)"
        case .reviewcutInstallId: return "ReviewCut 0.1 설치 ID (VRN-)"
        case .manual: return "기타(직접 입력)"
        }
    }

    /// 정규화 규칙이 있는 체계인지
    public var hasNormalization: Bool {
        self == .lmsPcV1 || self == .rentaldeskMachineV0
    }

    /// 입력값 정규화. 규칙이 있는 체계: 공백·하이픈 제거 → 대문자.
    /// 규칙이 없는 체계: 앞뒤 공백만 제거(대소문자·하이픈·앞자리 0 보존).
    public func normalize(_ input: String) -> String {
        switch self {
        case .lmsPcV1, .rentaldeskMachineV0:
            let kept = input.unicodeScalars.filter { !$0.properties.isWhitespace && $0 != "-" }
            return String(String.UnicodeScalarView(kept)).uppercased()
        case .reviewcutInstallId, .manual:
            return input.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// 정규화한 값이 이 체계의 형식인지
    public func isValid(normalized: String) -> Bool {
        switch self {
        case .lmsPcV1: return TextRules.isBase32(normalized, length: 25)
        case .rentaldeskMachineV0: return TextRules.isBase32(normalized, length: 20)
        case .reviewcutInstallId: return PcScheme.isReviewCutInstallId(normalized)
        case .manual: return !normalized.isEmpty && TextRules.length(normalized) <= 200 && !TextRules.hasControl(normalized)
        }
    }

    /// 형식 오류 안내 문구
    public var formatHint: String {
        switch self {
        case .lmsPcV1: return "공통 PC 번호는 영문 대문자와 숫자 2~7로 된 25자입니다. 예) ABCDE-FGHIJ-KLMNO-PQRST-UVWXY"
        case .rentaldeskMachineV0: return "RentalDesk 기기 코드는 영문 대문자와 숫자 2~7로 된 20자입니다. 예) ABCD-EFGH-IJKL-MNOP-QRST"
        case .reviewcutInstallId: return "ReviewCut 설치 ID는 VRN-XXXX-XXXX-XXXX 형식입니다(대문자·숫자)."
        case .manual: return "PC 번호를 1~200자로 입력하세요(줄바꿈 등 제어 문자 제외)."
        }
    }

    /// 화면 표시 형식(하이픈 묶음)
    public func display(normalized: String) -> String {
        switch self {
        case .lmsPcV1: return Self.group(normalized, size: 5)
        case .rentaldeskMachineV0: return Self.group(normalized, size: 4)
        case .reviewcutInstallId, .manual: return normalized
        }
    }

    private static func group(_ s: String, size: Int) -> String {
        let chars = Array(s)
        return stride(from: 0, to: chars.count, by: size)
            .map { String(chars[$0..<min($0 + size, chars.count)]) }
            .joined(separator: "-")
    }

    /// `^VRN-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$` (ReviewCut 발급 도구와 같은 규칙)
    public static func isReviewCutInstallId(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "VRN" else { return false }
        return parts.dropFirst().allSatisfy { p in
            p.unicodeScalars.count == 4 && p.unicodeScalars.allSatisfy { TextRules.isUpper($0.value) || TextRules.isDigit($0.value) }
        }
    }

    /// 입력 모양으로 체계를 제안한다(사용자가 확인). 25자 → 공통, 20자 → RentalDesk, `VRN-` → ReviewCut.
    public static func suggest(for input: String) -> PcScheme {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.uppercased().hasPrefix("VRN-") { return .reviewcutInstallId }
        if lmsPcV1.isValid(normalized: lmsPcV1.normalize(trimmed)) { return .lmsPcV1 }
        if rentaldeskMachineV0.isValid(normalized: rentaldeskMachineV0.normalize(trimmed)) { return .rentaldeskMachineV0 }
        return .manual
    }
}

/// 공통 PC 번호 계산(규격 2절). 관리 프로그램은 PC 번호를 직접 계산하지 않고 고객이 보낸 값을 받는다.
/// 이 함수는 테스트 벡터 확인용이다.
public enum PcIdV1 {
    public static func deviceHash(raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return TextRules.hex(Data(SHA256.hash(data: Data(trimmed.utf8))))
    }

    public static func pcId(deviceHash: String) -> String {
        let digest = Data(SHA256.hash(data: Data("LMS-PC-ID:v1:\(deviceHash)".utf8)))
        return String(Base32.encode(digest).prefix(25))
    }

    public static func pcId(raw: String) -> String { pcId(deviceHash: deviceHash(raw: raw)) }
}

/// RFC 4648 Base32 (패딩 없음)
public enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    public static func encode(_ data: Data) -> String {
        var out = ""
        var value: UInt32 = 0
        var bits = 0
        for byte in data {
            value = (value << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[Int((value >> UInt32(bits - 5)) & 31)])
                bits -= 5
            }
            value &= (1 << UInt32(bits)) - 1
        }
        if bits > 0 {
            out.append(alphabet[Int((value << UInt32(5 - bits)) & 31)])
        }
        return out
    }
}
