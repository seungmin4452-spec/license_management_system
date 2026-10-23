import LicenseCore
import LicenseStore
import SwiftUI
import UniformTypeIdentifiers

/// 라이선스 목록: 관리 번호, 고객, 제품, PC 번호, 상태, 유효기간. 검색어·필터는 AppModel에 있어 상세 화면을 다녀와도 유지된다.
struct LicensesView: View {
    @EnvironmentObject var model: AppModel
    @State private var rows: LoadState<[LicenseRow]> = .loading
    @State private var products: [Product] = []
    @State private var selected = Set<Int64>()

    var body: some View {
        VStack(spacing: 0) {
            LicenseFilterBar(filter: $model.licenseFilter, products: products)
                .padding(10)
            Divider()
            LoadView(state: rows, retry: reload) { list in
                if list.isEmpty {
                    if model.licenseFilter == LicenseFilter() {
                        EmptyStateView(symbol: "key", title: "발급한 라이선스가 없습니다",
                                       message: "상단의 '라이선스 발급' 버튼으로 발급하거나, 가져오기 화면에서 기존 기록을 옮기세요.")
                    } else {
                        EmptyStateView(symbol: "magnifyingglass", title: "조건에 맞는 라이선스가 없습니다", message: "검색어나 필터를 바꿔 보세요.")
                    }
                } else {
                    LicenseTable(rows: list, selected: $selected)
                }
            }
        }
        .navigationTitle("라이선스")
        .toolbar {
            ToolbarItem {
                Button { exportCurrent() } label: { Label("현재 결과 CSV로 내보내기", systemImage: "square.and.arrow.up") }
                    .help("현재 검색 결과를 CSV로 내보냅니다")
            }
        }
        .onAppear(perform: reload)
        .onChange(of: model.licenseFilter) { _, _ in reload() }
        .onChange(of: model.revision) { _, _ in reload() }
    }

    func reload() {
        guard let s = model.services else { return }
        products = (try? s.products.list()) ?? []
        rows = load { try s.queries.licenses(model.licenseFilter) }
    }

    func exportCurrent() {
        guard let s = model.services, case .loaded(let list) = rows else { return }
        guard let url = FilePanels.save(name: "licenses.csv", types: [.commaSeparatedText],
                                        message: "현재 검색 결과(\(list.count)건)를 UTF-8 CSV로 저장합니다. 고객 정보가 들어 있으니 보관에 주의하세요.") else { return }
        model.run("내보내지 못했습니다") { try s.importExport.exportCSV(list).write(to: url, options: .atomic) }
    }
}

struct LicenseFilterBar: View {
    @Binding var filter: LicenseFilter
    let products: [Product]

    var body: some View {
        HStack(spacing: 10) {
            TextField("이 목록에서 검색(고객·제품·PC 번호·관리 번호)", text: $filter.query)
                .textFieldStyle(.roundedBorder).frame(minWidth: 220)
            Picker("제품", selection: $filter.productId) {
                Text("전체 제품").tag(Int64?.none)
                ForEach(products) { p in Text(p.name).tag(p.id) }
            }
            .frame(width: 180)
            Picker("처리 상태", selection: $filter.status) {
                Text("전체").tag(ProcessingStatus?.none)
                ForEach(ProcessingStatus.allCases) { s in Text(s.displayName).tag(ProcessingStatus?.some(s)) }
            }
            .frame(width: 160)
            Picker("유효 상태", selection: $filter.effective) {
                Text("전체").tag(EffectiveStatus?.none)
                ForEach([EffectiveStatus.notYetValid, .valid, .expired]) { s in Text(s.displayName).tag(EffectiveStatus?.some(s)) }
            }
            .frame(width: 160)
            Picker("만료 예정", selection: $filter.expiringWithinDays) {
                Text("제한 없음").tag(Int?.none)
                Text("7일 이내").tag(Int?.some(7))
                Text("30일 이내").tag(Int?.some(30))
                Text("90일 이내").tag(Int?.some(90))
            }
            .frame(width: 170)
            Picker("정렬", selection: $filter.sort) {
                ForEach(LicenseSort.allCases) { s in Text(s.displayName).tag(s) }
            }
            .frame(width: 170)
            if filter != LicenseFilter() {
                Button("필터 초기화") { filter = LicenseFilter() }
            }
        }
    }
}

struct LicenseTable: View {
    @EnvironmentObject var model: AppModel
    let rows: [LicenseRow]
    @Binding var selected: Set<Int64>

    var body: some View {
        let now = Date()
        Table(rows, selection: $selected) {
            TableColumn("관리 번호") { r in Text(r.license.managementNo).font(.body.monospaced()) }
                .width(min: 110, ideal: 120)
            TableColumn("고객") { r in Text(r.customerName) }
            TableColumn("제품") { r in Text(r.productName) }
            TableColumn("PC 번호") { r in
                Text(r.pcDisplay).font(.body.monospaced()).lineLimit(1).truncationMode(.middle).help(r.pcDisplay)
            }
            .width(min: 150, ideal: 230)
            TableColumn("상태") { r in
                HStack(spacing: 4) {
                    StatusBadge(r.effective(now: now))
                    if r.license.verification == .unverified { StatusBadge(verification: .unverified) }
                }
            }
            .width(min: 120, ideal: 170)
            TableColumn("유효기간(서울)") { r in Text(Fmt.period(r.license)).lineLimit(1) }
                .width(min: 180, ideal: 240)
        }
        .contextMenu(forSelectionType: Int64.self) { ids in
            if let id = ids.first {
                Button("상세 보기") { model.open(.license(id)) }
                if let r = rows.first(where: { $0.id == id }) {
                    Button("PC 번호 복사") { model.copy(r.pcDisplay) }
                    Button("관리 번호 복사") { model.copy(r.license.managementNo) }
                }
            }
        } primaryAction: { ids in
            if let id = ids.first { model.open(.license(id)) }
        }
    }
}

// MARK: - 상세

struct LicenseDetailView: View {
    @EnvironmentObject var model: AppModel
    let licenseId: Int64
    @State private var detail: LoadState<LicenseDetail> = .loading
    @State private var memo = ""
    @State private var cancelling = false

    var body: some View {
        LoadView(state: detail, retry: reload) { d in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(d)
                    actions(d)
                    GroupBox("발급 정보") { info(d).padding(6) }
                    GroupBox("발급 당시 조건(파일에 기록된 값)") { conditions(d).padding(6) }
                    GroupBox("이전·후속 라이선스") { relations(d).padding(6) }
                    GroupBox("메모") {
                        HStack {
                            TextField("메모", text: $memo, axis: .vertical).lineLimit(2...5)
                            Button("저장") {
                                model.run { try model.services?.licenses.updateMemo(licenseId: licenseId, memo: memo) }
                                model.changed()
                            }
                            .disabled(memo == d.row.license.memo)
                        }
                        .padding(6)
                    }
                    GroupBox("변경 이력") { AuditList(logs: d.auditLogs).padding(6) }
                }
                .padding()
            }
        }
        .navigationTitle(detailTitle)
        .onAppear(perform: reload)
        .onChange(of: model.revision) { _, _ in reload() }
        .sheet(isPresented: $cancelling) {
            if case .loaded(let d) = detail {
                CancelLicenseSheet(license: d.row.license) { cancelling = false; model.changed() }
                    .environmentObject(model)
            }
        }
    }

    var detailTitle: String {
        if case .loaded(let d) = detail { return d.row.license.managementNo }
        return "라이선스"
    }

    func reload() {
        guard let s = model.services else { return }
        detail = load { try s.queries.licenseDetail(licenseId) }
        if case .loaded(let d) = detail { memo = d.row.license.memo }
    }

    @ViewBuilder
    func header(_ d: LicenseDetail) -> some View {
        let l = d.row.license
        HStack(alignment: .center, spacing: 10) {
            Text(l.managementNo).font(.title2.monospaced().weight(.semibold)).textSelection(.enabled)
            StatusBadge(l.effectiveStatus(now: Date()))
            StatusBadge(text: l.status.displayName, color: .secondary)
            StatusBadge(verification: l.verification)
            Spacer()
        }
        if l.verification == .unverified {
            Label("호환성 미검증: 서명이 확인되지 않은 기록입니다. 표시된 기간은 관리상 기간이며, 고객 프로그램이 이 기간을 강제하는지는 확인되지 않았습니다.",
                  systemImage: "questionmark.diamond")
                .font(.callout).foregroundStyle(.purple)
        }
    }

    @ViewBuilder
    func actions(_ d: LicenseDetail) -> some View {
        let l = d.row.license
        HStack {
            if let file = l.licenseFile {
                Button { copyText(file, l) } label: { Label("라이선스 문자열 복사", systemImage: "doc.on.doc") }
                Button { saveFile(file, l, asText: false) } label: { Label("라이선스 파일 저장", systemImage: "square.and.arrow.down") }
                Button { saveFile(file, l, asText: true) } label: { Label("텍스트(.txt) 저장", systemImage: "doc.text") }
            }
            Spacer()
            if l.status == .issued {
                Button("갱신…") { model.issueMode = .renew(l) }
                Button("PC 교체…") { model.issueMode = .replace(l) }
                Button("발급 취소…", role: .destructive) { cancelling = true }
            }
        }
    }

    func copyText(_ file: Data, _ l: License) {
        model.copy(String(decoding: file, as: UTF8.self))
        model.services?.licenses.recordExport(licenseId: l.id!, what: "라이선스 문자열 복사")
    }

    func saveFile(_ file: Data, _ l: License, asText: Bool) {
        let base = (l.licenseFileName ?? "license-\(l.managementNo).json") as NSString
        let name = asText ? base.deletingPathExtension + ".txt" : base as String
        guard let url = FilePanels.save(name: name, types: asText ? [.plainText] : [.json, .data]) else { return }
        // 재발급하지 않고 저장된 원본을 그대로 다시 저장한다
        if model.run("저장하지 못했습니다", { try file.write(to: url, options: .atomic) }) != nil {
            model.services?.licenses.recordExport(licenseId: l.id!, what: asText ? "텍스트 저장" : "파일 저장")
        }
    }

    @ViewBuilder
    func info(_ d: LicenseDetail) -> some View {
        let l = d.row.license
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                KeyValueRow(key: "고객", value: d.customer.name)
                Button("고객 보기") { model.open(.customer(d.customer.id!)) }.buttonStyle(.link)
            }
            HStack {
                KeyValueRow(key: "제품", value: "\(d.product.name) [\(d.product.code)]")
                Button("제품 보기") { model.open(.product(d.product.id!)) }.buttonStyle(.link)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("PC 번호").foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
                PCNumberText(scheme: d.pc.scheme, normalized: d.pc.numberNormalized)
                Text("(\(d.pc.scheme.displayName)\(d.pc.alias.isEmpty ? "" : " · \(d.pc.alias)"))").font(.caption).foregroundStyle(.secondary)
            }
            KeyValueRow(key: "시작(서울)", value: LicenseTime.seoulDisplay(l.startsDate, seconds: true))
            KeyValueRow(key: "만료", value: Fmt.expiryDetail(l.expiresDate))
            KeyValueRow(key: "저장된 UTC", value: "[\(l.startsAt), \(l.expiresAt ?? "영구"))", monospaced: true)
            KeyValueRow(key: "발급 시각(서울)", value: LicenseTime.seoulDisplay(l.issuedDate, seconds: true))
            KeyValueRow(key: "발급 방식", value: l.issueMethod.displayName)
            KeyValueRow(key: "생성 방식", value: "\(l.generator?.displayName ?? l.generatorId) \(l.generatorVersion)")
            KeyValueRow(key: "서명 key_id", value: l.keyId ?? "")
            KeyValueRow(key: "파일 안 라이선스 ID", value: l.fileLicenseId ?? "", monospaced: true, copyable: true)
            KeyValueRow(key: "검증", value: l.verificationDetail)
            KeyValueRow(key: "외부 관리 번호", value: l.externalRef ?? "")
            if let src = l.importSource { KeyValueRow(key: "가져온 원본", value: src) }
            if l.status != .issued {
                KeyValueRow(key: "\(l.status.displayName) 사유", value: l.statusReason ?? "")
                KeyValueRow(key: "처리 시각", value: Fmt.seoulUTC(l.statusChangedAt))
            }
        }
    }

    @ViewBuilder
    func conditions(_ d: LicenseDetail) -> some View {
        let c = d.row.license.conditions
        VStack(alignment: .leading, spacing: 4) {
            ForEach(c.keys.sorted(), id: \.self) { k in
                KeyValueRow(key: k, value: c[k] ?? "", monospaced: true)
            }
            if let payload = d.row.license.signedPayload {
                DisclosureGroup("서명 대상 원문") {
                    Text(payload).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    func relations(_ d: LicenseDetail) -> some View {
        if d.predecessors.isEmpty && d.successors.isEmpty {
            Text("연결된 라이선스가 없습니다.").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(d.predecessors) { r in
                    relationRow("이전", r)
                }
                ForEach(d.successors) { r in
                    relationRow("후속", r)
                }
            }
        }
    }

    func relationRow(_ label: String, _ r: RelationRow) -> some View {
        HStack {
            Text("\(label) · \(r.relation.kind.displayName)").frame(width: 120, alignment: .leading).foregroundStyle(.secondary)
            Button(r.otherManagementNo) { model.open(.license(r.otherLicenseId)) }.buttonStyle(.link)
            Text(r.relation.reason.isEmpty ? "" : "사유: \(r.relation.reason)")
            Spacer()
            Text(Fmt.seoulUTC(r.relation.createdAt)).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct AuditList: View {
    let logs: [AuditLog]
    var body: some View {
        if logs.isEmpty {
            Text("이력이 없습니다.").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(logs) { log in
                    HStack(alignment: .firstTextBaseline) {
                        Text(Fmt.seoulUTC(log.at)).font(.caption.monospaced()).frame(width: 130, alignment: .leading)
                        Text(log.action).font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                        Text(log.summary + (log.reason.isEmpty ? "" : " — 사유: \(log.reason)")).font(.callout)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}

// MARK: - 취소

struct CancelLicenseSheet: View {
    @EnvironmentObject var model: AppModel
    let license: License
    let done: () -> Void
    @State private var reason = ""
    @State private var confirm = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("발급 취소: \(license.managementNo)").font(.title3.weight(.semibold))
            OfflineNotice()
            Text("취소해도 기록은 삭제되지 않고 '취소됨'으로 남습니다. 되돌릴 수 없습니다.").font(.callout)
            TextField("취소 사유(필수)", text: $reason, axis: .vertical).lineLimit(2...4)
            FieldError(message: reason.trimmingCharacters(in: .whitespaces).isEmpty ? "사유를 입력해야 취소할 수 있습니다." : nil)
            HStack {
                Spacer()
                Button("닫기") { dismiss() }
                Button("취소 처리", role: .destructive) { confirm = true }
                    .disabled(reason.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .confirmationDialog("\(license.managementNo)을(를) 취소 처리할까요?", isPresented: $confirm) {
            Button("취소 처리", role: .destructive) {
                if model.run({ try model.services?.licenses.cancel(licenseId: license.id!, reason: reason) }) != nil {
                    done()
                    dismiss()
                }
            }
        } message: {
            Text("고객 PC의 라이선스는 원격으로 중지되지 않습니다. 이 프로그램의 기록만 '취소됨'이 됩니다.")
        }
    }
}
