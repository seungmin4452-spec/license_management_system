import AppKit
import LicenseCore
import LicenseStore
import SwiftUI
import UniformTypeIdentifiers

// MARK: 상태 표시(색 + 텍스트)

struct StatusBadge: View {
    let text: String
    let color: Color

    init(_ status: EffectiveStatus) {
        text = status.displayName
        switch status {
        case .valid: color = .green
        case .notYetValid: color = .blue
        case .expired: color = .orange
        case .cancelled: color = .red
        case .superseded: color = .gray
        }
    }

    init(verification: Verification) {
        text = verification.displayName
        color = verification == .verified ? .teal : .purple
    }

    init(text: String, color: Color) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.6), lineWidth: 0.5))
            .foregroundStyle(color)
            .accessibilityLabel(text)
    }
}

// MARK: 긴 PC 번호: 말줄임 + 전체 보기 + 복사

struct PCNumberText: View {
    @EnvironmentObject var model: AppModel
    let scheme: PcScheme
    let normalized: String
    @State private var showFull = false

    var display: String { scheme.display(normalized: normalized) }

    var body: some View {
        HStack(spacing: 4) {
            Text(display)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .help(display)
            Button { showFull = true } label: { Image(systemName: "eye") }
                .buttonStyle(.borderless).help("전체 보기")
                .popover(isPresented: $showFull) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(scheme.displayName).font(.caption).foregroundStyle(.secondary)
                        Text(display).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                        if scheme.hasNormalization && display != normalized {
                            Text("정규화 값: \(normalized)").font(.caption.monospaced()).textSelection(.enabled)
                        }
                        Button("복사") { model.copy(display); showFull = false }
                    }
                    .padding()
                }
            Button { model.copy(display) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("PC 번호 복사")
        }
    }
}

// MARK: 빈 목록·결과 없음·로딩·실패

struct EmptyStateView: View {
    let symbol: String
    let title: String
    var message: String = ""

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 32)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// 비동기 없이 읽는 목록 화면용 상태
enum LoadState<T> {
    case loading
    case loaded(T)
    case failed(String)
}

struct LoadView<T, Content: View>: View {
    let state: LoadState<T>
    let retry: () -> Void
    @ViewBuilder let content: (T) -> Content

    var body: some View {
        switch state {
        case .loading: ProgressView("불러오는 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let msg):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 28)).foregroundStyle(.orange)
                Text("불러오지 못했습니다").font(.headline)
                Text(msg).font(.callout).foregroundStyle(.secondary)
                Button("다시 시도", action: retry)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let value): content(value)
        }
    }
}

func load<T>(_ work: () throws -> T) -> LoadState<T> {
    do { return .loaded(try work()) } catch {
        return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }
}

// MARK: 입력 오류(필드 가까이)

struct FieldError: View {
    let message: String?
    var body: some View {
        if let message, !message.isEmpty {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct IssueList: View {
    let issues: [ValidationIssue]
    var body: some View {
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(issues) { issue in
                    Label(issue.message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// 오프라인 라이선스 안내(취소·PC 교체 화면)
struct OfflineNotice: View {
    var body: some View {
        Label("오프라인 라이선스는 이 프로그램에서 취소·대체해도 고객 PC에 이미 전달된 라이선스가 원격으로 중지되지 않습니다. 이 기록은 관리용입니다.",
              systemImage: "wifi.slash")
            .font(.callout)
            .padding(10)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: 키·값 표

struct KeyValueRow: View {
    let key: String
    let value: String
    var monospaced = false
    var copyable = false
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
                .lineLimit(3).truncationMode(.middle)
            if copyable && !value.isEmpty {
                Button { model.copy(value) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("복사")
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: 날짜 표시

enum Fmt {
    static func seoul(_ date: Date?) -> String {
        guard let date else { return "—" }
        return LicenseTime.seoulDisplay(date)
    }

    static func seoulUTC(_ s: String?) -> String {
        guard let s, let d = LicenseTime.parseUTC(s) else { return "—" }
        return LicenseTime.seoulDisplay(d)
    }

    /// 유효기간 한 줄
    static func period(_ l: License) -> String {
        let start = LicenseTime.seoulDisplay(l.startsDate)
        guard let e = l.expiresDate else { return "\(start) ~ 영구" }
        return "\(start) ~ \(LicenseTime.lastUseDay(expiresAt: e)) 까지"
    }

    /// 만료 설명: 마지막 사용일 + 실제 만료 시각
    static func expiryDetail(_ e: Date?) -> String {
        guard let e else { return "만료 없음(영구)" }
        return "\(LicenseTime.lastUseDay(expiresAt: e))까지 사용 · 만료 시각 \(LicenseTime.seoulDisplay(e)) (서울, 이 시각부터 만료)"
    }
}

/// DatePicker를 서울 시간대 기준으로 표시하기 위한 환경값
extension View {
    func seoulCalendar() -> some View {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return self.environment(\.timeZone, cal.timeZone).environment(\.calendar, cal)
    }
}

// MARK: 파일 대화상자

enum FilePanels {
    static func save(name: String, types: [UTType], message: String? = nil) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = types
        panel.canCreateDirectories = true
        if let message { panel.message = message }
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func open(types: [UTType], multiple: Bool = false, message: String? = nil) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = false
        if let message { panel.message = message }
        return panel.runModal() == .OK ? panel.urls : []
    }

    static let sqlite = UTType(filenameExtension: "sqlite") ?? .data
    static let pem = UTType(filenameExtension: "pem") ?? .data
}

struct SectionHeader: View {
    let title: String
    var body: some View { Text(title).font(.title3.weight(.semibold)).padding(.top, 8) }
}
