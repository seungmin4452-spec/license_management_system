import AppKit
import Foundation
import LicenseCore
import LicenseStore
import SwiftUI

/// 왼쪽 메뉴
enum AppSection: String, CaseIterable, Identifiable {
    case dashboard, customers, products, licenses, importExport, settings, search
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashboard: return "대시보드"
        case .customers: return "고객·PC"
        case .products: return "제품"
        case .licenses: return "라이선스"
        case .importExport: return "가져오기·내보내기"
        case .settings: return "백업·설정"
        case .search: return "검색 결과"
        }
    }
    var symbol: String {
        switch self {
        case .dashboard: return "gauge"
        case .customers: return "person.2"
        case .products: return "shippingbox"
        case .licenses: return "key"
        case .importExport: return "arrow.up.arrow.down.square"
        case .settings: return "externaldrive"
        case .search: return "magnifyingglass"
        }
    }
}

/// 화면 이동 대상
enum Route: Hashable {
    case customer(Int64)
    case product(Int64)
    case license(Int64)
}

/// 발급 창을 여는 방법
enum IssueMode: Identifiable, Equatable {
    case new(customerId: Int64?, pcId: Int64?, productId: Int64?)
    case renew(License)
    case replace(License)
    case manual(customerId: Int64?, pcId: Int64?, productId: Int64?)

    var id: String {
        switch self {
        case .new(let c, let p, let pr): return "new-\(c ?? 0)-\(p ?? 0)-\(pr ?? 0)"
        case .renew(let l): return "renew-\(l.id ?? 0)"
        case .replace(let l): return "replace-\(l.id ?? 0)"
        case .manual(let c, let p, let pr): return "manual-\(c ?? 0)-\(p ?? 0)-\(pr ?? 0)"
        }
    }
}

struct AlertItem: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// 앱 전체 상태. 검색어·필터·화면 경로를 여기에 두어 상세 화면을 다녀와도 유지한다.
final class AppModel: ObservableObject {
    static let keychainService = "kr.lms.LicenseManager.signing-keys"

    @Published private(set) var services: AppServices?
    @Published var loadError: String?
    @Published var section: AppSection = .dashboard
    @Published var paths: [AppSection: NavigationPath] = [:]
    @Published var globalSearch = ""
    @Published var submittedSearch = ""
    @Published var licenseFilter = LicenseFilter()
    @Published var customerQuery = ""
    @Published var showArchivedCustomers = false
    @Published var issueMode: IssueMode?
    @Published var alert: AlertItem?
    /// 데이터가 바뀌면 증가 → 목록 다시 읽기
    @Published var revision = 0

    private let lock = SingleInstanceLock()
    private var productionServices: AppServices?

    var isDemo: Bool { services?.isDemo ?? false }

    init() {
        do {
            let root = try AppPaths.standard()
            guard lock.acquire(at: root.lockURL) else {
                loadError = "라이선스 관리 프로그램이 이미 실행 중입니다. 같은 데이터베이스는 한 번에 하나의 창에서만 쓸 수 있습니다."
                return
            }
            let s = try AppServices.openProduction(keychainService: Self.keychainService)
            productionServices = s
            services = s
            AppLogger.shared?.log("INFO", "앱 시작")
        } catch {
            loadError = "데이터베이스를 열 수 없습니다: \(error.localizedDescription)"
        }
    }

    // MARK: 이동

    func path(_ s: AppSection) -> Binding<NavigationPath> {
        Binding(get: { self.paths[s] ?? NavigationPath() }, set: { self.paths[s] = $0 })
    }

    func open(_ route: Route) {
        let target: AppSection
        switch route {
        case .customer: target = .customers
        case .product: target = .products
        case .license: target = .licenses
        }
        section = target
        var p = paths[target] ?? NavigationPath()
        p.append(route)
        paths[target] = p
    }

    func submitSearch() {
        submittedSearch = globalSearch
        if !globalSearch.trimmingCharacters(in: .whitespaces).isEmpty { section = .search }
    }

    // MARK: 작업 실행·오류 표시

    func changed() { revision += 1 }

    /// 오류는 알림으로 보여주고 nil을 돌려준다(입력값은 화면에 그대로 남는다)
    @discardableResult
    func run<T>(_ title: String = "처리하지 못했습니다", _ work: () throws -> T) -> T? {
        do {
            let r = try work()
            return r
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            alert = AlertItem(title: title, message: msg)
            AppLogger.shared?.log("WARN", "\(title): \(type(of: error))")
            return nil
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: 데모

    func openDemo() {
        guard let demo = run("데모 데이터를 만들지 못했습니다", { try AppServices.openDemo() }) else { return }
        services = demo
        resetNavigation()
    }

    func closeDemo() {
        guard let prod = productionServices else { return }
        try? services?.database.close()
        services = prod
        resetNavigation()
    }

    private func resetNavigation() {
        paths = [:]
        licenseFilter = LicenseFilter()
        globalSearch = ""
        submittedSearch = ""
        section = .dashboard
        changed()
    }

    // MARK: 종료 시 자동 백업

    func terminationReply() -> NSApplication.TerminateReply {
        guard let s = productionServices, s.settings.autoBackupOnQuit else { return .terminateNow }
        while true {
            do {
                let url = try s.backup.autoBackup()
                AppLogger.shared?.log("INFO", "종료 시 자동 백업: \(url.lastPathComponent)")
                return .terminateNow
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "종료 전 자동 백업에 실패했습니다"
                alert.informativeText = "\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)\n\n다시 시도하거나, 백업 없이 종료할 수 있습니다."
                alert.addButton(withTitle: "다시 시도")
                alert.addButton(withTitle: "백업 없이 종료")
                alert.addButton(withTitle: "종료 취소")
                switch alert.runModal() {
                case .alertFirstButtonReturn: continue
                case .alertSecondButtonReturn:
                    AppLogger.shared?.log("WARN", "자동 백업 없이 종료(사용자 선택)")
                    return .terminateNow
                default: return .terminateCancel
                }
            }
        }
    }
}
