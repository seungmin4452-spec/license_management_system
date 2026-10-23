import LicenseCore
import LicenseStore
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var model: AppModel
    @State private var stats: LoadState<DashboardStats> = .loading
    @State private var expiring: LoadState<[LicenseRow]> = .loading
    @State private var withinDays = 30
    @State private var sortOrder = [KeyPathComparator(\ExpiringItem.expires)]
    @State private var selected = Set<Int64>()

    struct ExpiringItem: Identifiable {
        let row: LicenseRow
        var id: Int64 { row.id }
        var expires: Date { row.license.expiresDate ?? .distantFuture }
        var customer: String { row.customerName }
        var product: String { row.productName }
        var managementNo: String { row.license.managementNo }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LoadView(state: stats, retry: reload) { s in
                HStack(spacing: 12) {
                    Tile(title: "제품", value: s.products, symbol: "shippingbox") { model.section = .products }
                    Tile(title: "고객", value: s.customers, symbol: "person.2") { model.section = .customers }
                    Tile(title: "현재 유효 라이선스", value: s.validLicenses, symbol: "checkmark.seal") {
                        model.licenseFilter = LicenseFilter(effective: .valid)
                        model.section = .licenses
                    }
                    Tile(title: "7일 이내 만료 예정", value: s.expiring7, symbol: "clock.badge.exclamationmark", tint: .orange) { withinDays = 7 }
                    Tile(title: "30일 이내 만료 예정", value: s.expiring30, symbol: "calendar.badge.clock", tint: .yellow) { withinDays = 30 }
                }
            }
            .frame(height: 110)

            HStack {
                Text("만료 예정 라이선스").font(.title3.weight(.semibold))
                Picker("", selection: $withinDays) {
                    Text("7일 이내").tag(7)
                    Text("30일 이내").tag(30)
                    Text("90일 이내").tag(90)
                }
                .pickerStyle(.segmented).frame(width: 260)
                Spacer()
                Text("취소·대체된 라이선스는 제외").font(.caption).foregroundStyle(.secondary)
            }

            LoadView(state: expiring, retry: reload) { rows in
                if rows.isEmpty {
                    EmptyStateView(symbol: "checkmark.circle", title: "\(withinDays)일 이내에 만료되는 라이선스가 없습니다")
                } else {
                    let items = rows.map(ExpiringItem.init).sorted(using: sortOrder)
                    Table(items, selection: $selected, sortOrder: $sortOrder) {
                        TableColumn("만료(서울)", value: \.expires) { item in
                            VStack(alignment: .leading) {
                                Text(Fmt.seoul(item.row.license.expiresDate))
                                Text("\(LicenseTime.lastUseDay(expiresAt: item.expires))까지 사용").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        TableColumn("관리 번호", value: \.managementNo)
                        TableColumn("고객", value: \.customer)
                        TableColumn("제품", value: \.product)
                        TableColumn("PC 번호") { item in Text(item.row.pcDisplay).font(.body.monospaced()).lineLimit(1).truncationMode(.middle) }
                        TableColumn("상태") { item in StatusBadge(item.row.effective(now: Date())) }
                    }
                    .contextMenu(forSelectionType: Int64.self) { _ in } primaryAction: { ids in
                        if let id = ids.first { model.open(.license(id)) }
                    }
                }
            }
        }
        .padding()
        .navigationTitle("대시보드")
        .onAppear(perform: reload)
        .onChange(of: withinDays) { _, _ in reload() }
        .onChange(of: model.revision) { _, _ in reload() }
    }

    func reload() {
        guard let s = model.services else { return }
        stats = load { try s.queries.dashboard() }
        expiring = load { try s.queries.licenses(LicenseFilter(expiringWithinDays: withinDays, sort: .expiresSoon)) }
    }

    struct Tile: View {
        let title: String
        let value: Int
        let symbol: String
        var tint: Color = .accentColor
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(title, systemImage: symbol).font(.callout).foregroundStyle(.secondary)
                    Text("\(value)").font(.system(size: 32, weight: .semibold)).foregroundStyle(tint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
    }
}
