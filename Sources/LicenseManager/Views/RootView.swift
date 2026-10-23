import AppKit
import LicenseCore
import LicenseStore
import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let error = model.loadError {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 40)).foregroundStyle(.orange)
                Text(error).multilineTextAlignment(.center).frame(maxWidth: 520)
                Button("종료") { NSApp.terminate(nil) }
            }
            .padding(40)
        } else if let services = model.services {
            MainView(services: services)
        } else {
            ProgressView("불러오는 중…")
        }
    }
}

struct MainView: View {
    @EnvironmentObject var model: AppModel
    let services: AppServices

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.section }, set: { if let s = $0 { model.section = s } })) {
                ForEach(AppSection.allCases.filter { $0 != .search || !model.submittedSearch.isEmpty }) { s in
                    Label(s.title, systemImage: s.symbol).tag(s)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) {
                if model.isDemo {
                    Label("데모 데이터 사용 중", systemImage: "theatermasks")
                        .font(.caption).foregroundStyle(.orange).padding(8)
                }
            }
        } detail: {
            NavigationStack(path: model.path(model.section)) {
                sectionView(model.section)
                    .navigationDestination(for: Route.self) { route in
                        switch route {
                        case .customer(let id): CustomerDetailView(customerId: id)
                        case .product(let id): ProductDetailView(productId: id)
                        case .license(let id): LicenseDetailView(licenseId: id)
                        }
                    }
            }
            .id(model.section)
        }
        .searchable(text: $model.globalSearch, placement: .toolbar, prompt: "고객·업체·제품·PC 번호·관리 번호 검색")
        .onSubmit(of: .search) { model.submitSearch() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.issueMode = .new(customerId: nil, pcId: nil, productId: nil)
                } label: {
                    Label("라이선스 발급", systemImage: "plus.rectangle.on.rectangle")
                }
                .help("새 라이선스 발급 또는 기존 라이선스 수동 등록")
            }
        }
        .sheet(item: $model.issueMode) { mode in
            IssueLicenseSheet(mode: mode).environmentObject(model)
        }
        .alert(model.alert?.title ?? "", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("확인", role: .cancel) { model.alert = nil }
        } message: {
            Text(model.alert?.message ?? "")
        }
    }

    @ViewBuilder
    func sectionView(_ s: AppSection) -> some View {
        switch s {
        case .dashboard: DashboardView()
        case .customers: CustomersView()
        case .products: ProductsView()
        case .licenses: LicensesView()
        case .importExport: ImportExportView()
        case .settings: SettingsView()
        case .search: SearchResultsView()
        }
    }
}
