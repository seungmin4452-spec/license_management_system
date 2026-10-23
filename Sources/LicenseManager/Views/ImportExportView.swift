import LicenseCore
import LicenseStore
import SwiftUI
import UniformTypeIdentifiers

struct ImportExportView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("CSV 가져오기").tag(0)
                Text("라이선스 파일 일괄 등록").tag(1)
                Text("내보내기·양식").tag(2)
            }
            .pickerStyle(.segmented).frame(width: 480).padding(10)
            Divider()
            switch tab {
            case 0: CSVImportView()
            case 1: BatchRegisterView()
            default: ExportView()
            }
        }
        .navigationTitle("가져오기·내보내기")
    }
}

// MARK: - CSV 가져오기: 파일 선택 → 컬럼 연결 → 검증 미리보기 → 최종 저장

struct CSVImportView: View {
    @EnvironmentObject var model: AppModel
    @State private var table: CSVTable?
    @State private var fileName = ""
    @State private var mapping: ImportMapping?
    @State private var plan: ImportPlan?
    @State private var products: [Product] = []
    @State private var step = 1
    @State private var showErrorsOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                stepLabel(1, "파일 선택")
                stepLabel(2, "컬럼 연결")
                stepLabel(3, "검증 미리보기")
                stepLabel(4, "저장")
                Spacer()
            }
            switch step {
            case 1: chooseFile
            case 2: mappingView
            default: previewView
            }
        }
        .padding()
        .onAppear { products = (try? model.services?.products.list(includeArchived: true)) ?? [] }
    }

    func stepLabel(_ n: Int, _ text: String) -> some View {
        Label(text, systemImage: step >= n ? "\(n).circle.fill" : "\(n).circle")
            .foregroundStyle(step == n ? Color.accentColor : .secondary)
    }

    var chooseFile: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("UTF-8 CSV 파일을 고르세요. 가져오기 단위는 라이선스 기록 한 줄입니다.").font(.callout)
            Text("RentalDesk 발급 도구의 issued_licenses.csv(키 폴더 ~/RentDeskSellerKeys/)도 바로 가져올 수 있습니다.").font(.callout)
            HStack {
                Button("CSV 파일 선택…") { pick() }
                Button("빈 양식 저장…") { saveTemplate() }
            }
            Text("오류가 하나라도 있으면 아무것도 저장하지 않습니다(전체 성공 또는 전체 취소). 같은 파일을 다시 가져와도 중복을 만들지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }

    func pick() {
        guard let url = FilePanels.open(types: [.commaSeparatedText, .plainText, .data], message: "가져올 CSV 파일").first else { return }
        do {
            let t = try CSV.parse(Data(contentsOf: url))
            table = t
            fileName = url.lastPathComponent
            let isLedger = t.header.contains("machine_code") && t.header.contains("customer_label")
            mapping = ImportExportService.defaultMapping(for: t, preset: isLedger ? .rentalDeskLedger : .standard, sourceName: fileName)
            plan = nil
            step = 2
        } catch {
            model.alert = AlertItem(title: "CSV를 읽을 수 없습니다", message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func saveTemplate() {
        guard let url = FilePanels.save(name: "license-import-template.csv", types: [.commaSeparatedText]) else { return }
        model.run { try ImportExportService.templateData().write(to: url, options: .atomic) }
    }

    @ViewBuilder
    var mappingView: some View {
        if let t = table, mapping != nil {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(fileName) · \(t.rows.count)행").font(.headline)
                    Spacer()
                    Picker("양식", selection: Binding(get: { mapping!.preset }, set: { p in
                        mapping = ImportExportService.defaultMapping(for: t, preset: p, sourceName: fileName)
                    })) {
                        ForEach(ImportPreset.allCases) { p in Text(p.displayName).tag(p) }
                    }
                    .frame(width: 380)
                }
                HStack {
                    Picker("모든 행의 제품", selection: Binding(get: { mapping!.fixedProductId }, set: { mapping!.fixedProductId = $0 })) {
                        Text("제품 코드 열 사용").tag(Int64?.none)
                        ForEach(products) { p in Text(p.name).tag(p.id) }
                    }
                    .frame(width: 320)
                    if mapping!.preset == .rentalDeskLedger && mapping!.fixedProductId == nil {
                        FieldError(message: "발급 내역 파일에는 제품 열이 없습니다. RentalDesk 제품을 고르세요.")
                    }
                }
                Toggle("파일 안에서 이름이 같은 신규 고객은 한 고객으로 만들기(기존 고객과는 병합하지 않음)",
                       isOn: Binding(get: { mapping!.mergeSameNameInFile }, set: { mapping!.mergeSameNameInFile = $0 }))
                Toggle("파일 안에서 같은 제품·PC 기간이 겹치면 앞 기록을 '대체됨'으로 가져오기(재발급 이력)",
                       isOn: Binding(get: { mapping!.supersedeOverlapsInFile }, set: { mapping!.supersedeOverlapsInFile = $0 }))
                if mapping!.preset == .rentalDeskLedger {
                    Text("format 열이 v1이면 공통 PC 번호(lms-pc-v1), 아니면 RentalDesk 기기 코드(rentaldesk-machine-v0)로 연결합니다. customer_label은 고객 이름 후보일 뿐 기존 고객과 자동 병합하지 않습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("컬럼 연결").font(.headline)
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        ForEach(ImportField.allCases) { f in
                            GridRow {
                                Text(f.displayName).frame(width: 170, alignment: .leading)
                                Picker("", selection: Binding(get: { mapping!.columns[f] }, set: { mapping!.columns[f] = $0 })) {
                                    Text("(연결 안 함)").tag(Int?.none)
                                    ForEach(Array(t.header.enumerated()), id: \.offset) { i, h in Text(h).tag(Int?.some(i)) }
                                }
                                .frame(width: 260)
                                Text(sample(t, mapping!.columns[f])).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                HStack {
                    Button("다른 파일") { step = 1; table = nil }
                    Spacer()
                    Button("검증 미리보기") { preview() }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    func sample(_ t: CSVTable, _ col: Int?) -> String {
        guard let first = t.rows.first else { return "" }
        let v = t.value(first, col)
        return v.isEmpty ? "" : "예: \(v)"
    }

    func preview() {
        guard let s = model.services, let t = table, let m = mapping else { return }
        if let p = model.run("검증하지 못했습니다", { try s.importExport.plan(t, m) }) {
            plan = p
            step = 3
        }
    }

    @ViewBuilder
    var previewView: some View {
        if let p = plan {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if p.hasErrors {
                        Label("오류 \(p.rows.filter { !$0.errors.isEmpty }.count)행 — 오류가 있으면 저장하지 않습니다", systemImage: "xmark.octagon").foregroundStyle(.red)
                    } else {
                        Label("저장할 기록 \(p.importCount)건, 건너뜀 \(p.skipCount)건", systemImage: "checkmark.circle").foregroundStyle(.green)
                    }
                    Spacer()
                    Toggle("오류 행만", isOn: $showErrorsOnly)
                }
                if !p.newCustomerNames.isEmpty {
                    Text("새로 만들 고객 \(p.newCustomerNames.count)명: \(p.newCustomerNames.prefix(20).joined(separator: ", "))\(p.newCustomerNames.count > 20 ? " …" : "")")
                        .font(.callout)
                }
                let rows = showErrorsOnly ? p.rows.filter { !$0.errors.isEmpty } : p.rows
                Table(rows) {
                    TableColumn("줄") { r in Text("\(r.line)").font(.body.monospaced()) }.width(40)
                    TableColumn("결과") { r in
                        if !r.errors.isEmpty { StatusBadge(text: "오류", color: .red) }
                        else if r.skip { StatusBadge(text: "건너뜀", color: .gray) }
                        else { StatusBadge(text: r.statusText, color: .green) }
                    }
                    .width(90)
                    TableColumn("고객") { r in Text(r.customerText) }
                    TableColumn("제품") { r in Text(r.productText) }
                    TableColumn("PC") { r in Text(r.pcText).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle) }
                    TableColumn("기간") { r in Text(r.periodText).font(.caption) }
                    TableColumn("오류·안내") { r in
                        Text((r.errors + r.warnings).joined(separator: " / "))
                            .font(.caption).foregroundStyle(r.errors.isEmpty ? Color.secondary : Color.red).lineLimit(3)
                            .help((r.errors + r.warnings).joined(separator: "\n"))
                    }
                }
                HStack {
                    Button("컬럼 연결로 돌아가기") { step = 2 }
                    Spacer()
                    Button("저장(\(p.importCount)건)") { commit() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(p.hasErrors || p.importCount == 0)
                }
            }
        }
    }

    func commit() {
        guard let s = model.services, let t = table, let m = mapping else { return }
        if let n = model.run("저장하지 않았습니다", { try s.importExport.commit(t, m) }) {
            model.changed()
            model.alert = AlertItem(title: "가져오기 완료", message: "\(n)건을 저장했습니다.")
            step = 1
            table = nil
            plan = nil
        } else {
            preview()
        }
    }
}

// MARK: - 라이선스 파일 일괄 등록(ReviewCut 등 발급 내역이 없는 제품)

struct BatchRegisterView: View {
    @EnvironmentObject var model: AppModel
    @State private var products: [Product] = []
    @State private var customers: [Customer] = []
    @State private var productId: Int64?
    @State private var items: [BatchFileItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("고객에게 보낸 라이선스 JSON 파일 여러 개를 한꺼번에 등록합니다. 서명을 확인하고 PC 번호·기간·라이선스 ID를 파일에서 채웁니다.")
                .font(.callout)
            HStack {
                Picker("제품", selection: $productId) {
                    Text("제품 선택").tag(Int64?.none)
                    ForEach(products) { p in Text(p.name).tag(p.id) }
                }
                .frame(width: 300)
                Button("라이선스 파일 선택…") { pick() }.disabled(productId == nil)
                Spacer()
            }
            Text("서명을 확인하려면 제품에 해당 key_id의 공개키(또는 비밀키)가 등록되어 있어야 합니다. 이름이 같아도 기존 고객과 자동으로 합치지 않습니다(필요하면 고객을 직접 고르세요).")
                .font(.caption).foregroundStyle(.secondary)
            if items.isEmpty {
                EmptyStateView(symbol: "doc.on.doc", title: "선택한 파일이 없습니다")
            } else {
                List {
                    ForEach($items) { $item in
                        BatchRow(item: $item, customers: customers)
                    }
                }
                HStack {
                    let ready = items.filter { $0.alreadyRegistered == nil && $0.isVerified && $0.problems.isEmpty }.count
                    let bad = items.filter { $0.alreadyRegistered == nil && (!$0.isVerified || !$0.problems.isEmpty) }.count
                    Text("등록 가능 \(ready)건 · 문제 \(bad)건 · 이미 등록 \(items.filter { $0.alreadyRegistered != nil }.count)건")
                    Spacer()
                    Button("모두 지우기") { items = [] }
                    Button("등록") { commit() }.keyboardShortcut(.defaultAction).disabled(bad > 0 || ready == 0)
                }
            }
        }
        .padding()
        .onAppear {
            products = (try? model.services?.products.list(includeArchived: false)) ?? []
            customers = (try? model.services?.customers.list(includeArchived: true)) ?? []
        }
    }

    func pick() {
        guard let s = model.services, let p = productId else { return }
        let urls = FilePanels.open(types: [.json, .plainText, .data], multiple: true, message: "라이선스 파일을 여러 개 고를 수 있습니다")
        guard !urls.isEmpty else { return }
        let files = urls.compactMap { url in (try? Data(contentsOf: url)).map { (name: url.lastPathComponent, data: $0) } }
        if let prepared = model.run("파일을 읽지 못했습니다", { try s.licenses.prepareBatch(files: files, productId: p) }) {
            items += prepared
        }
    }

    func commit() {
        guard let s = model.services, let p = productId else { return }
        if let n = model.run("등록하지 않았습니다", { try s.licenses.commitBatch(items, productId: p) }) {
            model.changed()
            model.alert = AlertItem(title: "일괄 등록 완료", message: "\(n)건을 등록했습니다.")
            items = []
            customers = (try? s.customers.list(includeArchived: true)) ?? []
        }
    }
}

struct BatchRow: View {
    @Binding var item: BatchFileItem
    let customers: [Customer]
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.fileName).font(.headline)
                if let no = item.alreadyRegistered { StatusBadge(text: "이미 등록(\(no))", color: .gray) }
                else if item.isVerified && item.problems.isEmpty { StatusBadge(text: "서명 확인됨", color: .teal) }
                else { StatusBadge(text: "문제 있음", color: .red) }
                Spacer()
                if let i = item.inspected {
                    Text(i.pcNumber.map { i.pcScheme.display(normalized: $0) } ?? "").font(.caption.monospaced())
                }
            }
            ForEach(item.problems, id: \.self) { p in Text(p).font(.caption).foregroundStyle(.red) }
            if item.alreadyRegistered == nil {
                HStack {
                    if let owner = item.existingPcOwnerName {
                        Text("이미 등록된 PC → 고객: \(owner)").font(.callout)
                    } else {
                        Picker("고객", selection: Binding(get: { choiceTag }, set: { setChoice($0) })) {
                            Text("새 고객").tag(Int64(0))
                            ForEach(customers) { c in Text(c.name).tag(c.id ?? -1) }
                        }
                        .frame(width: 260)
                        if case .new = item.customer {
                            TextField("새 고객 이름", text: Binding(get: { if case .new(let n) = item.customer { return n } else { return "" } },
                                                                 set: { item.customer = .new($0) }))
                                .frame(width: 220)
                        }
                    }
                    Spacer()
                    if let i = item.inspected {
                        Text("\(i.licensee ?? "표시명 없음") · \(i.startsAt.map { LicenseTime.seoulDisplay($0) } ?? "?") · \(i.isPerpetual ? "영구" : Fmt.expiryDetail(i.expiresAt))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    var choiceTag: Int64 {
        if case .existing(let id) = item.customer { return id }
        return 0
    }

    func setChoice(_ tag: Int64) {
        if tag == 0 {
            item.customer = .new(item.inspected?.licensee ?? (item.fileName as NSString).deletingPathExtension)
        } else {
            item.customer = .existing(tag)
        }
    }
}

// MARK: - 내보내기·양식

struct ExportView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("현재 검색 결과 내보내기") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("라이선스 화면의 현재 검색어·필터 결과를 UTF-8 CSV로 저장합니다. PC 번호의 앞자리 0과 한글을 그대로 보존합니다.")
                    Button("CSV로 내보내기…") { export() }
                }
                .padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("CSV 가져오기 양식") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("개인정보가 없는 예제 행이 들어 있는 양식입니다. 열 설명은 README와 docs/csv-import.md에 있습니다.")
                    Button("양식 저장…") {
                        guard let url = FilePanels.save(name: "license-import-template.csv", types: [.commaSeparatedText]) else { return }
                        model.run { try ImportExportService.templateData().write(to: url, options: .atomic) }
                    }
                }
                .padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("CSV 안전 정책") {
                Text("""
                • =, +, -, @, 탭, CR로 시작하는 셀은 표 계산 프로그램에서 수식으로 실행되지 않도록 앞에 작은따옴표(')를 붙여 저장합니다. 이 프로그램으로 다시 가져오면 작은따옴표를 떼어 원래 값으로 복원합니다.
                • 엑셀에서 열 때 앞자리 0이 사라질 수 있으니 '데이터 가져오기'에서 해당 열을 텍스트로 지정하세요(파일 안의 값은 보존됨).
                • 라이선스 원문은 CSV에 넣지 않습니다. 고객에게 보낼 파일은 라이선스 상세 화면의 '라이선스 파일 저장'을 쓰세요.
                """)
                .font(.callout).padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
        }
        .padding()
    }

    func export() {
        guard let s = model.services else { return }
        guard let rows = model.run({ try s.queries.licenses(model.licenseFilter) }) else { return }
        guard let url = FilePanels.save(name: "licenses.csv", types: [.commaSeparatedText],
                                        message: "\(rows.count)건을 저장합니다. 고객 정보가 들어 있으니 보관에 주의하세요.") else { return }
        model.run("내보내지 못했습니다") { try s.importExport.exportCSV(rows).write(to: url, options: .atomic) }
    }
}
