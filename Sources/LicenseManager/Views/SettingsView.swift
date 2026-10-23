import AppKit
import LicenseCore
import LicenseStore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var keep = 30
    @State private var onQuit = true
    @State private var autoBackups: [URL] = []
    @State private var restoreCandidate: BackupInspection?
    @State private var restoreCurrent: (customers: Int, products: Int, licenses: Int)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let s = model.services {
                    GroupBox("데이터 위치") {
                        VStack(alignment: .leading, spacing: 6) {
                            KeyValueRow(key: "데이터베이스", value: s.paths.databaseURL.path, monospaced: true, copyable: true)
                            KeyValueRow(key: "자동 백업 폴더", value: s.paths.backupsDir.path, monospaced: true)
                            KeyValueRow(key: "로그 폴더", value: s.paths.logsDir.path, monospaced: true)
                            HStack {
                                Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([s.paths.databaseURL]) }
                            }
                            Label("데이터베이스와 백업 파일에는 고객 정보와 라이선스가 들어 있습니다. 기본 데이터베이스는 암호화되어 있지 않으니 FileVault 등으로 Mac을 보호하고, 백업 파일 보관에 주의하세요.",
                                  systemImage: "lock.trianglebadge.exclamationmark")
                                .font(.callout).foregroundStyle(.orange)
                            Text("네트워크 공유 폴더의 데이터베이스를 여러 PC에서 동시에 쓰는 방식은 지원하지 않습니다.").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(6)
                    }

                    GroupBox("백업") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("SQLite 온라인 백업 기능으로 일관된 복사본을 만듭니다. 라이선스 파일과 이력도 함께 들어갑니다.").font(.callout)
                            Text("서명 비밀키는 백업에 들어가지 않습니다(이 Mac의 키체인에만 있음). 다른 Mac에서 복원하면 제품 화면에서 서명 키를 다시 가져와야 자동 발급할 수 있습니다.")
                                .font(.callout)
                            HStack {
                                Button("지금 백업…") { manualBackup(s) }
                                Button("백업에서 복원…") { pickRestore(s) }
                            }
                            Divider()
                            Toggle("프로그램 종료 시 자동 백업", isOn: $onQuit)
                                .onChange(of: onQuit) { _, v in _ = model.run { try s.settings.setAutoBackupOnQuit(v) } }
                            Stepper("자동 백업 보존 개수: \(keep)개(수동 백업은 자동 삭제하지 않음)", value: $keep, in: 1...365)
                                .onChange(of: keep) { _, v in _ = model.run { try s.settings.setAutoBackupKeep(v) } }
                            Text("최근 자동 백업 \(autoBackups.count)개").font(.caption).foregroundStyle(.secondary)
                            ForEach(autoBackups.prefix(5), id: \.self) { url in
                                Text(url.lastPathComponent).font(.caption.monospaced())
                            }
                        }
                        .padding(6)
                    }

                    GroupBox("서명 키와 오프라인 라이선스") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("• 서명 비밀키는 소스·DB·설정·로그·일반 백업에 넣지 않고 macOS 키체인에만 저장합니다(이 기기, 잠금 해제 시).")
                            Text("• 오프라인 라이선스는 이 프로그램에서 취소·대체해도 고객 PC에 이미 전달된 라이선스가 원격으로 중지되지 않습니다.")
                            Text("• 로컬 데이터베이스의 변경 이력은 관리용 기록이며, 위변조 방지 증거가 아닙니다.")
                        }
                        .font(.callout).padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("데모 데이터") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("예제 데이터는 운영 데이터와 분리된 데모 데이터베이스(\(AppPaths.appIdentifier)/Demo)에만 만듭니다. 데모를 열 때마다 새로 만들고, 데모의 서명 키는 메모리에만 둡니다.")
                                .font(.callout)
                            if model.isDemo {
                                Button("데모 닫고 운영 데이터로 돌아가기") { model.closeDemo() }
                            } else {
                                Button("데모 데이터베이스 열기") { model.openDemo() }
                            }
                        }
                        .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("최근 변경 이력") {
                        AuditList(logs: (try? s.queries.recentAudit(limit: 50)) ?? []).padding(6)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("백업·설정")
        .onAppear(perform: reload)
        .onChange(of: model.revision) { _, _ in reload() }
        .confirmationDialog("이 백업으로 복원할까요?", isPresented: Binding(get: { restoreCandidate != nil }, set: { if !$0 { restoreCandidate = nil } }),
                            presenting: restoreCandidate) { info in
            Button("복원", role: .destructive) { restore(info) }
        } message: { info in
            Text(restoreMessage(info))
        }
    }

    func reload() {
        guard let s = model.services else { return }
        keep = s.settings.autoBackupKeep
        onQuit = s.settings.autoBackupOnQuit
        autoBackups = s.backup.autoBackups()
    }

    func manualBackup(_ s: AppServices) {
        let name = "LicenseManager-backup-\(BackupNames.stamp(Date())).sqlite"
        guard let url = FilePanels.save(name: name, types: [FilePanels.sqlite], message: "백업 파일에는 고객 정보와 라이선스가 들어 있습니다.") else { return }
        if model.run("백업하지 못했습니다", { try s.backup.manualBackup(to: url) }) != nil {
            model.alert = AlertItem(title: "백업했습니다", message: url.path)
            model.changed()
        }
    }

    func pickRestore(_ s: AppServices) {
        guard let url = FilePanels.open(types: [FilePanels.sqlite, .data], message: "복원할 백업 파일을 고르세요").first else { return }
        guard let info = model.run("복원할 수 없는 백업입니다", { try s.backup.inspect(url) }) else { return }
        restoreCurrent = try? s.database.read { db -> (customers: Int, products: Int, licenses: Int) in
            (customers: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM customer") ?? 0,
             products: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM product") ?? 0,
             licenses: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM license") ?? 0)
        }
        restoreCandidate = info
    }

    func restoreMessage(_ info: BackupInspection) -> String {
        var text = "백업: 고객 \(info.customers) · 제품 \(info.products) · 라이선스 \(info.licenses)"
        if let last = info.lastActivity { text += " (마지막 기록 \(Fmt.seoulUTC(last)))" }
        if let c = restoreCurrent { text += "\n현재: 고객 \(c.customers) · 제품 \(c.products) · 라이선스 \(c.licenses)" }
        text += "\n\n현재 데이터는 복원 전에 자동 백업 폴더에 따로 저장됩니다. 복원 중에는 쓰기를 멈추고, 실패하면 기존 데이터로 되돌립니다. 서명 비밀키는 백업에 없으므로 다른 Mac의 백업이면 키를 다시 가져와야 합니다."
        return text
    }

    func restore(_ info: BackupInspection) {
        guard let s = model.services else { return }
        if let safety = model.run("복원하지 못했습니다", { try s.backup.restore(from: info.url) }) {
            model.changed()
            model.alert = AlertItem(title: "복원했습니다", message: "복원 전 데이터는 여기에 저장했습니다:\n\(safety.path)")
        }
    }
}

struct SearchResultsView: View {
    @EnvironmentObject var model: AppModel
    @State private var result: LoadState<UnifiedSearchResult> = .loading
    @State private var selected = Set<Int64>()

    var body: some View {
        LoadView(state: result, retry: reload) { r in
            if r.isEmpty {
                EmptyStateView(symbol: "magnifyingglass", title: "‘\(model.submittedSearch)’ 검색 결과가 없습니다",
                               message: "고객명·업체명·제품명/코드·PC 번호·관리 번호로 찾을 수 있습니다. PC 번호는 하이픈·대소문자와 상관없이 찾습니다.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !r.pcs.isEmpty {
                            GroupBox("PC (\(r.pcs.count))") {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(r.pcs) { item in
                                        HStack {
                                            PCNumberText(scheme: item.pc.scheme, normalized: item.pc.numberNormalized)
                                            Text(item.pc.scheme.displayName).font(.caption).foregroundStyle(.secondary)
                                            Spacer()
                                            Button("고객: \(item.customerName)") { model.open(.customer(item.pc.customerId)) }.buttonStyle(.link)
                                        }
                                    }
                                }
                                .padding(6)
                            }
                        }
                        if !r.customers.isEmpty {
                            GroupBox("고객 (\(r.customers.count))") {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(r.customers) { c in
                                        HStack {
                                            Button(c.name) { model.open(.customer(c.id!)) }.buttonStyle(.link)
                                            if !c.contactPerson.isEmpty { Text(c.contactPerson).foregroundStyle(.secondary) }
                                            if c.isArchived { StatusBadge(text: "보관", color: .gray) }
                                        }
                                    }
                                }
                                .padding(6)
                            }
                        }
                        if !r.licenses.isEmpty {
                            GroupBox("라이선스 (\(r.licenses.count))") {
                                LicenseTable(rows: r.licenses, selected: $selected)
                                    .frame(minHeight: 200, idealHeight: CGFloat(60 + 28 * r.licenses.count), maxHeight: 500)
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("검색: \(model.submittedSearch)")
        .onAppear(perform: reload)
        .onChange(of: model.submittedSearch) { _, _ in reload() }
        .onChange(of: model.revision) { _, _ in reload() }
    }

    func reload() {
        guard let s = model.services else { return }
        result = load { try s.queries.search(model.submittedSearch) }
    }
}
