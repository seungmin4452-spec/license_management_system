import LicenseCore
import LicenseStore
import SwiftUI
import UniformTypeIdentifiers

/// 라이선스 발급 창. 입력 순서: 고객 → 제품 → PC → 영구/기간제 → 시작·만료 → 메모.
/// 자동 발급(기본), 기존 파일 수동 등록, 갱신, PC 교체를 한 창에서 처리한다.
struct IssueLicenseSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let mode: IssueMode

    enum Method: String { case auto, manual }
    enum StartMode: String { case now, date, exact }
    enum TermMode: String { case months, lastDay, exact }

    @State private var method: Method = .auto
    @State private var customers: [Customer] = []
    @State private var products: [Product] = []
    @State private var pcs: [CustomerPC] = []
    @State private var customerId: Int64?
    @State private var productId: Int64?
    @State private var pcId: Int64?
    @State private var productDetail: ProductDetail?
    @State private var generatorId: GeneratorID?

    @State private var perpetual = true
    @State private var startMode: StartMode = .now
    @State private var startDate = Date()
    @State private var termMode: TermMode = .months
    @State private var months = 12
    @State private var lastDayDate = Date()
    @State private var exactExpiry = Date()

    @State private var licensee = ""
    @State private var edition = "standard"
    @State private var maxVersion = ""
    @State private var memo = ""
    @State private var externalRef = ""
    @State private var reason = ""
    @State private var supersede = false
    @State private var renewPlan: RenewPlan?

    @State private var requestToken = UUID().uuidString
    @State private var issues: [ValidationIssue] = []
    @State private var isSaving = false
    @State private var result: License?
    @State private var confirming = false
    @State private var initialized = false
    @State private var addingPC = false

    // 수동 등록
    @State private var fileData: Data?
    @State private var fileName: String?
    @State private var pasteText = ""
    @State private var inspected: InspectedLicense?
    @State private var inspectedUnknown = false

    var old: License? {
        switch mode {
        case .renew(let l), .replace(let l): return l
        default: return nil
        }
    }
    var isRenew: Bool { if case .renew = mode { return true } else { return false } }
    var isReplace: Bool { if case .replace = mode { return true } else { return false } }

    var title: String {
        if isRenew { return "라이선스 갱신" }
        if isReplace { return "PC 교체(새 PC에 재발급)" }
        return method == .auto ? "라이선스 발급" : "기존 라이선스 수동 등록"
    }

    var caps: GeneratorCapabilities? { generatorId.flatMap { GeneratorRegistry.generator(for: $0)?.capabilities } }
    var selectedPC: CustomerPC? { pcs.first { $0.id == pcId } }
    var selectedCustomer: Customer? { customers.first { $0.id == customerId } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.title2.weight(.semibold))
                Spacer()
                if old == nil && result == nil {
                    Picker("", selection: $method) {
                        Text("자동 발급").tag(Method.auto)
                        Text("기존 파일 수동 등록").tag(Method.manual)
                    }
                    .pickerStyle(.segmented).frame(width: 260)
                }
            }
            .padding([.horizontal, .top], 20).padding(.bottom, 10)
            Divider()
            if let r = result {
                IssueResultView(license: r) { dismiss() }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let o = old { oldBox(o) }
                        targetBox
                        if method == .auto { autoBoxes } else { manualBoxes }
                        GroupBox("메모") {
                            VStack(alignment: .leading) {
                                TextField("메모(관리용, 파일에 들어가지 않음)", text: $memo, axis: .vertical).lineLimit(1...4)
                                TextField("외부 관리 번호(주문 번호 등, 선택)", text: $externalRef)
                            }
                            .padding(6)
                        }
                        IssueList(issues: issues.filter { $0.field == .general || $0.field == .key })
                    }
                    .padding(20)
                }
                Divider()
                footer.padding(16)
            }
        }
        .frame(width: 700, height: 780)
        .onAppear(perform: setup)
        .onChange(of: signature) { _, _ in recheck() }
        .sheet(isPresented: $addingPC, onDismiss: { reloadPCs() }) {
            if let c = customerId { PCFormSheet(customerId: c).environmentObject(model) }
        }
        .confirmationDialog(confirmTitle, isPresented: $confirming) {
            Button(isReplace ? "PC 교체 진행" : "기존 라이선스 대체 후 발급", role: .destructive) { perform() }
        } message: {
            Text("기존 라이선스 \(old?.managementNo ?? "")은(는) 같은 트랜잭션에서 '대체됨' 처리됩니다. 발급에 실패하면 기존 라이선스는 그대로 유지됩니다.\n고객 PC에 이미 전달된 기존 라이선스는 원격으로 중지되지 않습니다.")
        }
    }

    var confirmTitle: String { isReplace ? "PC를 교체할까요?" : "기존 라이선스를 대체 처리할까요?" }

    // MARK: 초기화

    func setup() {
        guard !initialized, let s = model.services else { return }
        initialized = true
        customers = (try? s.customers.list()) ?? []
        products = ((try? s.products.list(includeArchived: false)) ?? []).filter(\.isActive)
        switch mode {
        case .new(let c, let p, let pr):
            customerId = c ?? customers.first?.id
            pcId = p
            productId = pr
        case .manual(let c, let p, let pr):
            method = .manual
            customerId = c ?? customers.first?.id
            pcId = p
            productId = pr
        case .renew(let l), .replace(let l):
            customerId = l.customerId
            productId = l.productId
            pcId = isReplace ? nil : l.pcId
            reason = ""
            if !products.contains(where: { $0.id == l.productId }), let p = try? s.products.detail(l.productId).product {
                products.append(p)
            }
            if let c = try? s.customers.get(l.customerId), !customers.contains(where: { $0.id == c.id }) { customers.append(c) }
        }
        reloadPCs()
        productChanged()
        if let c = selectedCustomer { licensee = String(c.name.prefix(100)) }
        if let o = old, let g = GeneratorID(rawValue: o.generatorId), g != .manual, isRenew || isReplace {
            if generatorId == nil || isRenew { generatorId = g }
            applyGeneratorDefaults()
            if let lic = o.conditions["licensee"], lic != "null", lic != "(없음)" { licensee = lic }
            if let cl = o.conditions["customer_label"] { licensee = cl }
            if let mv = o.conditions["max_version"], mv != "null" { maxVersion = mv }
            if let ut = o.conditions["updates_through"] { maxVersion = ut }
        }
        if isRenew, let o = old, let g = generatorId {
            let plan = s.licenses.renewPlan(for: o, generatorId: g, termMonths: productDetail?.product.defaultTermMonths ?? (o.isPerpetual ? nil : 12))
            renewPlan = plan
            supersede = plan.mustSupersede
            startMode = plan.suggestedStart > Date().addingTimeInterval(60) ? .exact : .now
            startDate = plan.suggestedStart
            if let e = plan.suggestedExpiry {
                perpetual = false
                termMode = .exact
                exactExpiry = e
            }
        }
        if isReplace, let o = old {
            supersede = true
            if let e = o.expiresDate {
                perpetual = false
                termMode = .exact
                exactExpiry = e
            } else {
                perpetual = true
            }
            if o.startsDate > Date(), caps?.futureStart == true {
                startMode = .exact
                startDate = o.startsDate
            }
        }
        recheck()
    }

    func reloadPCs() {
        guard let s = model.services, let c = customerId else { pcs = []; return }
        pcs = (try? s.customers.pcs(customerId: c)) ?? []
        if isReplace, let o = old { pcs.removeAll { $0.id == o.pcId } }
        if let p = pcId, !pcs.contains(where: { $0.id == p }) { pcId = nil }
        if pcId == nil, pcs.count == 1 { pcId = pcs.first?.id }
        chooseGenerator()
    }

    func productChanged() {
        guard let s = model.services, let p = productId else { productDetail = nil; generatorId = nil; return }
        productDetail = try? s.products.detail(p)
        chooseGenerator()
    }

    /// PC 번호 체계에 맞는 생성 방식 자동 선택
    func chooseGenerator() {
        let options = availableGenerators
        if let g = generatorId, options.contains(g) { return }
        generatorId = options.first
        applyGeneratorDefaults()
    }

    var availableGenerators: [GeneratorID] {
        guard let d = productDetail, let pc = selectedPC else { return [] }
        return d.enabledGenerators.filter { $0 != .manual && $0.scheme == pc.scheme }
    }

    func applyGeneratorDefaults() {
        guard let g = generatorId, let d = productDetail else { return }
        switch g {
        case .lmsLicenseV1:
            edition = d.product.defaultEdition
            maxVersion = d.product.defaultMaxVersion ?? ""
        case .reviewcutLegacy:
            edition = "full"
            maxVersion = ""
        case .rentaldeskLegacy:
            edition = "standard"
            maxVersion = d.product.defaultMaxVersion ?? RentalDeskLegacy.defaultUpdatesThrough
        case .manual: break
        }
        if old == nil {
            perpetual = d.product.defaultTermMonths == nil
            months = d.product.defaultTermMonths ?? 12
            termMode = .months
        }
        if let c = caps {
            if !c.term { perpetual = true }
            if !c.futureStart { startMode = .now }
        }
    }

    // MARK: 계산된 기간

    var computedStart: Date {
        let now = LicenseTime.truncated(Date())
        if method == .auto, let c = caps, !c.futureStart { return now }
        switch startMode {
        case .now: return now
        case .date: return LicenseTime.seoulMidnight(LicenseTime.seoulDate(of: startDate))
        case .exact: return LicenseTime.truncated(startDate)
        }
    }

    var computedExpiry: Date? {
        if perpetual { return nil }
        switch termMode {
        case .months:
            return LicenseTime.endExclusive(lastDay: LicenseTime.lastDay(start: LicenseTime.seoulDate(of: computedStart), months: months))
        case .lastDay:
            return LicenseTime.endExclusive(lastDay: LicenseTime.seoulDate(of: lastDayDate))
        case .exact:
            return LicenseTime.truncated(exactExpiry)
        }
    }

    var predecessor: Predecessor? {
        guard let o = old, let id = o.id else { return nil }
        if isReplace { return Predecessor(licenseId: id, kind: .replacement, reason: reason, supersede: true) }
        return Predecessor(licenseId: id, kind: .renewal, reason: reason, supersede: supersede)
    }

    var issueForm: IssueForm? {
        guard let c = customerId, let p = productId, let pc = pcId, let g = generatorId else { return nil }
        return IssueForm(customerId: c, productId: p, pcId: pc, generatorId: g, startsAt: computedStart, expiresAt: computedExpiry,
                         licensee: licensee, edition: edition, maxVersion: maxVersion, memo: memo, externalRef: externalRef,
                         requestToken: requestToken, predecessor: predecessor)
    }

    /// 입력이 바뀌면 다시 검사하기 위한 값
    var signature: String {
        [method.rawValue, "\(customerId ?? 0)", "\(productId ?? 0)", "\(pcId ?? 0)", generatorId?.rawValue ?? "",
         "\(perpetual)", startMode.rawValue, "\(startDate.timeIntervalSince1970)", termMode.rawValue, "\(months)",
         "\(lastDayDate.timeIntervalSince1970)", "\(exactExpiry.timeIntervalSince1970)", licensee, edition, maxVersion,
         reason, "\(supersede)", "\(fileData?.count ?? -1)", pasteText.count.description].joined(separator: "|")
    }

    func recheck() {
        guard let s = model.services else { return }
        if method == .auto {
            guard let f = issueForm else {
                issues = []
                return
            }
            issues = s.licenses.check(f)
        } else {
            issues = []
            if let e = computedExpiry, e <= computedStart, !(inspected?.check == .verified) {
                issues = [ValidationIssue(.expiry, "만료 시각은 시작 시각보다 늦어야 합니다.")]
            }
        }
    }

    func issuesFor(_ fields: ValidationIssue.Field...) -> [ValidationIssue] {
        issues.filter { fields.contains($0.field) }
    }

    // MARK: 화면 조각

    func oldBox(_ o: License) -> some View {
        GroupBox(isReplace ? "교체할 기존 라이선스" : "갱신할 기존 라이선스") {
            VStack(alignment: .leading, spacing: 4) {
                KeyValueRow(key: "관리 번호", value: o.managementNo, monospaced: true)
                KeyValueRow(key: "기간", value: Fmt.period(o))
                KeyValueRow(key: "생성 방식", value: o.generator?.displayName ?? o.generatorId)
                if let plan = renewPlan { Text(plan.explanation).font(.callout).fixedSize(horizontal: false, vertical: true) }
                if isRenew {
                    Toggle("기존 라이선스를 같은 트랜잭션에서 '대체됨' 처리", isOn: $supersede)
                        .disabled(renewPlan?.mustSupersede == true)
                }
                TextField(isReplace ? "PC 교체 사유(필수, 예: 메인보드 교체)" : "갱신 사유(선택)", text: $reason)
                if isReplace { FieldError(message: reason.trimmingCharacters(in: .whitespaces).isEmpty ? "PC 교체 사유를 입력하세요." : nil) }
                if isReplace || supersede { OfflineNotice() }
            }
            .padding(6)
        }
    }

    var targetBox: some View {
        GroupBox("대상") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("고객", selection: $customerId) {
                    Text("고객 선택").tag(Int64?.none)
                    ForEach(customers) { c in Text(c.name + (c.isArchived ? " (보관)" : "")).tag(c.id) }
                }
                .disabled(old != nil)
                .onChange(of: customerId) { _, _ in
                    if old == nil, let c = selectedCustomer { licensee = String(c.name.prefix(100)) }
                    reloadPCs()
                }
                if customers.isEmpty { FieldError(message: "먼저 고객을 등록하세요(고객·PC 메뉴).") }
                Picker("제품", selection: $productId) {
                    Text("제품 선택").tag(Int64?.none)
                    ForEach(products) { p in Text(p.name).tag(p.id) }
                }
                .disabled(old != nil)
                .onChange(of: productId) { _, _ in productChanged() }
                HStack {
                    Picker("PC", selection: $pcId) {
                        Text("PC 선택").tag(Int64?.none)
                        ForEach(pcs) { pc in
                            Text("\(pc.displayNumber)  ·  \(pc.scheme.displayName)\(pc.alias.isEmpty ? "" : "  ·  \(pc.alias)")").tag(pc.id)
                        }
                    }
                    .disabled(isRenew)
                    .onChange(of: pcId) { _, _ in chooseGenerator() }
                    Button("PC 등록…") { addingPC = true }.disabled(customerId == nil || isRenew)
                }
                IssueList(issues: issuesFor(.pc))
                if method == .auto {
                    if productId != nil && pcId != nil && availableGenerators.isEmpty {
                        FieldError(message: "이 제품은 선택한 PC 번호 체계(\(selectedPC?.scheme.displayName ?? ""))로 자동 발급할 수 없습니다. 제품의 생성 방식을 확인하거나 수동 등록을 쓰세요.")
                    } else if availableGenerators.count > 1 {
                        Picker("생성 방식", selection: $generatorId) {
                            ForEach(availableGenerators) { g in Text(g.displayName).tag(GeneratorID?.some(g)) }
                        }
                    } else if let g = generatorId {
                        KeyValueRow(key: "생성 방식", value: "\(g.displayName) (PC 번호 체계로 자동 선택)")
                    }
                }
            }
            .padding(6)
        }
    }

    @ViewBuilder
    var autoBoxes: some View {
        GroupBox("유효기간") { periodEditor(managementOnly: false).padding(6) }
        GroupBox("라이선스 파일 내용") {
            VStack(alignment: .leading, spacing: 6) {
                TextField("고객 표시명(상호 등)", text: $licensee)
                Text("라이선스 파일에 들어갑니다. 연락처·이메일은 넣지 마세요.\(generatorId == .rentaldeskLegacy ? " RentalDesk 이전 형식은 필수입니다." : "")")
                    .font(.caption).foregroundStyle(.secondary)
                IssueList(issues: issuesFor(.licensee))
                if generatorId == .lmsLicenseV1 {
                    TextField("에디션", text: $edition)
                    IssueList(issues: issuesFor(.edition))
                }
                if generatorId != .reviewcutLegacy {
                    TextField(generatorId == .rentaldeskLegacy ? "업데이트 허용 버전(주.부, 예: 1.0)" : "사용 가능 최고 버전(주.부, 비우면 제한 없음)", text: $maxVersion)
                    IssueList(issues: issuesFor(.maxVersion, .options, .productCode))
                }
            }
            .padding(6)
        }
    }

    @ViewBuilder
    func periodEditor(managementOnly: Bool) -> some View {
        let c = caps
        VStack(alignment: .leading, spacing: 8) {
            if managementOnly {
                Text("관리상 기간입니다. 서명이 확인되지 않은 라이선스는 고객 프로그램이 이 기간을 강제하는지 알 수 없습니다.")
                    .font(.caption).foregroundStyle(.purple)
            }
            Picker("종류", selection: $perpetual) {
                Text("영구").tag(true)
                Text("기간제").tag(false)
            }
            .pickerStyle(.segmented).frame(width: 240)
            .disabled(!managementOnly && c?.term == false)
            if !managementOnly, c?.term == false {
                Text("이 생성 방식은 영구 라이선스만 지원합니다.").font(.caption).foregroundStyle(.secondary)
            }
            if !managementOnly, c?.futureStart == false {
                Text("시작: 발급 즉시(이 생성 방식은 미래 시작을 지원하지 않습니다)").font(.callout)
            } else {
                HStack {
                    Picker("시작", selection: $startMode) {
                        Text("지금").tag(StartMode.now)
                        Text("날짜(서울 00:00)").tag(StartMode.date)
                        Text("날짜·시각").tag(StartMode.exact)
                    }
                    .frame(width: 260)
                    if startMode == .date {
                        DatePicker("", selection: $startDate, displayedComponents: .date).labelsHidden().seoulCalendar()
                    } else if startMode == .exact {
                        DatePicker("", selection: $startDate, displayedComponents: [.date, .hourAndMinute]).labelsHidden().seoulCalendar()
                    }
                }
            }
            IssueList(issues: issuesFor(.start))
            if !perpetual {
                HStack {
                    Picker("만료", selection: $termMode) {
                        Text("개월 수").tag(TermMode.months)
                        Text("마지막 사용일").tag(TermMode.lastDay)
                        Text("만료 시각 직접").tag(TermMode.exact)
                    }
                    .frame(width: 260)
                    switch termMode {
                    case .months:
                        Stepper("\(months)개월", value: $months, in: 1...120)
                    case .lastDay:
                        DatePicker("", selection: $lastDayDate, displayedComponents: .date).labelsHidden().seoulCalendar()
                    case .exact:
                        DatePicker("", selection: $exactExpiry, displayedComponents: [.date, .hourAndMinute]).labelsHidden().seoulCalendar()
                    }
                }
                if termMode == .months {
                    Text("시작일 + \(months)개월 같은 날짜(그 달에 없으면 말일)가 마지막 사용일입니다.").font(.caption).foregroundStyle(.secondary)
                }
            }
            IssueList(issues: issuesFor(.period, .expiry))
            periodSummary
        }
    }

    var periodSummary: some View {
        let s = computedStart
        let e = computedExpiry
        return VStack(alignment: .leading, spacing: 2) {
            Text("시작: \(LicenseTime.seoulDisplay(s)) (서울)\(startMode == .now || caps?.futureStart == false ? " — 발급 시각" : "")")
            if let e {
                Text("포함되는 마지막 날짜: \(LicenseTime.lastUseDay(expiresAt: e).description) (서울)")
                Text("실제 만료 시각: \(LicenseTime.seoulDisplay(e)) (서울) — 이 시각부터 만료")
                if generatorId == .rentaldeskLegacy && method == .auto {
                    Text("RentalDesk 이전 형식 파일에는 \(LicenseTime.seoulDisplay(RentalDeskLegacy.fileExpiry(fromManagement: e), seconds: true))(서울)로 기록됩니다.")
                }
            } else {
                Text("만료 없음(영구)")
            }
            Text("저장(UTC): [\(LicenseTime.utcString(s)), \(e.map(LicenseTime.utcString) ?? "영구"))").font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    var manualBoxes: some View {
        GroupBox("라이선스 파일 또는 문자열") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("파일 선택…") { pickFile() }
                    Text(fileName ?? "선택한 파일 없음").foregroundStyle(.secondary)
                    Spacer()
                    if fileData != nil { Button("지우기") { fileData = nil; fileName = nil; inspected = nil; inspectedUnknown = false } }
                }
                Text("또는 라이선스 문자열 붙여 넣기").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $pasteText).font(.caption.monospaced()).frame(height: 80)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                    .onChange(of: pasteText) { _, v in
                        if !v.isEmpty { fileData = Data(v.utf8); fileName = "붙여넣은 문자열.txt"; inspect() }
                    }
                Text("파일 없이 기록만 등록하려면 비워 두세요. 공통·이전 형식 파일이면 서명을 확인하고 내용(PC 번호, 기간, 라이선스 ID)을 자동으로 채웁니다.")
                    .font(.caption).foregroundStyle(.secondary)
                inspectionView
            }
            .padding(6)
        }
        if !(inspected?.check == .verified) {
            GroupBox("관리상 유효기간") { periodEditor(managementOnly: true).padding(6) }
        }
    }

    @ViewBuilder
    var inspectionView: some View {
        if inspectedUnknown {
            Label("알 수 없는 형식입니다. '호환성 미검증'으로 등록됩니다.", systemImage: "questionmark.diamond").foregroundStyle(.purple)
        } else if let i = inspected {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(i.generatorID.displayName).font(.headline)
                    StatusBadge(text: i.check.displayText, color: i.check == .verified ? .teal : .purple)
                }
                if i.check != .verified {
                    Text("서명을 확인하지 못해 '호환성 미검증'으로 등록됩니다. 서명을 확인하려면 제품 화면에서 해당 key_id의 공개키를 등록하세요.")
                        .font(.caption).foregroundStyle(.purple)
                }
                KeyValueRow(key: "PC 번호", value: i.pcNumber.map { i.pcScheme.display(normalized: $0) } ?? "", monospaced: true)
                KeyValueRow(key: "라이선스 ID", value: i.licenseId ?? "", monospaced: true)
                KeyValueRow(key: "key_id", value: i.keyId ?? "")
                KeyValueRow(key: "표시명", value: i.licensee ?? "")
                KeyValueRow(key: "기간", value: "\(i.startsAt.map { LicenseTime.seoulDisplay($0) } ?? "?") ~ \(Fmt.expiryDetail(i.expiresAt))")
                if let number = i.pcNumber {
                    if let match = pcs.first(where: { $0.scheme == i.pcScheme && $0.numberNormalized == number }) {
                        if pcId != match.id { Button("이 PC 선택") { pcId = match.id } }
                    } else if customerId != nil {
                        Button("파일의 PC 번호를 이 고객에 등록하고 선택") { registerInspectedPC(i, number) }
                    }
                }
            }
        }
    }

    var footer: some View {
        HStack {
            if isSaving { ProgressView().controlSize(.small); Text("저장 중…").foregroundStyle(.secondary) }
            Spacer()
            Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(method == .auto ? (isReplace ? "새 PC에 발급" : "발급") : "등록") { submit() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
        }
    }

    var canSubmit: Bool {
        if isSaving { return false }
        if isReplace && reason.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if method == .auto { return issueForm != nil && issues.isEmpty }
        return customerId != nil && productId != nil && pcId != nil && issues.isEmpty
    }

    // MARK: 동작

    func pickFile() {
        guard let url = FilePanels.open(types: [.json, .plainText, .data], message: "등록할 라이선스 파일을 고르세요").first else { return }
        guard let data = try? Data(contentsOf: url) else {
            model.alert = AlertItem(title: "파일을 읽을 수 없습니다", message: url.lastPathComponent)
            return
        }
        fileData = data
        fileName = url.lastPathComponent
        pasteText = ""
        inspect()
    }

    func inspect() {
        guard let s = model.services, let data = fileData else { return }
        inspected = s.licenses.inspect(fileBytes: data, productId: productId)
        inspectedUnknown = inspected == nil
        if let i = inspected, let number = i.pcNumber,
           let match = pcs.first(where: { $0.scheme == i.pcScheme && $0.numberNormalized == number }) {
            pcId = match.id
        }
        recheck()
    }

    func registerInspectedPC(_ i: InspectedLicense, _ number: String) {
        guard let s = model.services, let c = customerId else { return }
        if let pc = model.run("PC를 등록하지 못했습니다", { try s.customers.addPC(customerId: c, PCInput(scheme: i.pcScheme, number: number)) }) {
            reloadPCs()
            pcId = pc.id
            model.changed()
        }
    }

    func submit() {
        if method == .auto && (isReplace || (isRenew && supersede)) {
            confirming = true
        } else {
            perform()
        }
    }

    /// 저장 중 버튼을 잠근다. 같은 requestToken이라 빠른 중복 클릭도 한 번만 저장된다.
    func perform() {
        guard let s = model.services, !isSaving else { return }
        isSaving = true
        DispatchQueue.main.async {
            defer { isSaving = false }
            if method == .auto {
                guard let f = issueForm else { return }
                if let l = model.run("발급하지 못했습니다", { try s.licenses.issue(f) }) {
                    result = l
                    model.changed()
                } else {
                    recheck()
                }
            } else {
                guard let c = customerId, let p = productId, let pc = pcId else { return }
                let form = ManualForm(customerId: c, productId: p, pcId: pc, fileBytes: fileData, fileName: fileName,
                                      startsAt: computedStart, expiresAt: computedExpiry, memo: memo, externalRef: externalRef,
                                      requestToken: requestToken)
                if let l = model.run("등록하지 못했습니다", { try s.licenses.registerManual(form) }) {
                    result = l
                    model.changed()
                }
            }
        }
    }
}

/// 발급 완료: 복사, 파일 저장(UTF-8 원본), 텍스트 저장. 저장에 실패해도 다시 발급하지 않고 재저장할 수 있다.
struct IssueResultView: View {
    @EnvironmentObject var model: AppModel
    let license: License
    let close: () -> Void
    @State private var savedTo: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(license.issueMethod == .auto ? "발급했습니다" : "등록했습니다", systemImage: "checkmark.circle.fill")
                .font(.title2).foregroundStyle(.green)
            KeyValueRow(key: "관리 번호", value: license.managementNo, monospaced: true, copyable: true)
            KeyValueRow(key: "기간", value: Fmt.period(license))
            KeyValueRow(key: "만료", value: Fmt.expiryDetail(license.expiresDate))
            HStack { Text("검증").foregroundStyle(.secondary).frame(width: 150, alignment: .leading); StatusBadge(verification: license.verification) }
            if let file = license.licenseFile {
                HStack {
                    Button { model.copy(String(decoding: file, as: UTF8.self)); savedTo = "클립보드에 복사했습니다." } label: {
                        Label("라이선스 문자열 복사", systemImage: "doc.on.doc")
                    }
                    Button { save(file, asText: false) } label: { Label("라이선스 파일 저장", systemImage: "square.and.arrow.down") }
                    Button { save(file, asText: true) } label: { Label("텍스트(.txt) 저장", systemImage: "doc.text") }
                }
                if let savedTo { Text(savedTo).font(.callout).foregroundStyle(.secondary) }
                Text("고객에게 파일을 보내고, 고객 프로그램의 라이선스 등록 화면에서 불러오게 안내하세요.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Button("상세 보기") { close(); model.open(.license(license.id!)) }
                Spacer()
                Button("닫기", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }

    func save(_ file: Data, asText: Bool) {
        let base = (license.licenseFileName ?? "license-\(license.managementNo).json") as NSString
        let name = asText ? base.deletingPathExtension + ".txt" : base as String
        guard let url = FilePanels.save(name: name, types: asText ? [.plainText] : [.json, .data]) else { return }
        if model.run("저장하지 못했습니다(다시 저장할 수 있습니다)", { try file.write(to: url, options: .atomic) }) != nil {
            savedTo = "저장했습니다: \(url.path)"
            model.services?.licenses.recordExport(licenseId: license.id!, what: asText ? "텍스트 저장" : "파일 저장")
        }
    }
}
