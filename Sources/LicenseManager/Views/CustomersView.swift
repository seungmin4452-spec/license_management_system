import LicenseCore
import LicenseStore
import SwiftUI

struct CustomersView: View {
    @EnvironmentObject var model: AppModel
    @State private var customers: LoadState<[Customer]> = .loading
    @State private var editing: CustomerFormTarget?
    @State private var selected = Set<Int64>()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("고객명·업체명·담당자 검색", text: $model.customerQuery).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                Toggle("보관된 고객 포함", isOn: $model.showArchivedCustomers)
                Spacer()
                Button { editing = .new } label: { Label("고객 등록", systemImage: "person.badge.plus") }
            }
            .padding(10)
            Divider()
            LoadView(state: customers, retry: reload) { list in
                if list.isEmpty {
                    if model.customerQuery.isEmpty {
                        EmptyStateView(symbol: "person.2", title: "등록된 고객이 없습니다", message: "'고객 등록'으로 고객을 추가하세요.")
                    } else {
                        EmptyStateView(symbol: "magnifyingglass", title: "검색 결과가 없습니다")
                    }
                } else {
                    Table(list, selection: $selected) {
                        TableColumn("고객명/업체명") { c in
                            HStack {
                                Text(c.name)
                                if c.isArchived { StatusBadge(text: "보관", color: .gray) }
                            }
                        }
                        TableColumn("담당자") { c in Text(c.contactPerson) }
                        TableColumn("연락처") { c in Text(c.phone) }
                        TableColumn("이메일") { c in Text(c.email) }
                        TableColumn("메모") { c in Text(c.memo).lineLimit(1) }
                    }
                    .contextMenu(forSelectionType: Int64.self) { _ in } primaryAction: { ids in
                        if let id = ids.first { model.open(.customer(id)) }
                    }
                }
            }
        }
        .navigationTitle("고객·PC")
        .onAppear(perform: reload)
        .onChange(of: model.customerQuery) { _, _ in reload() }
        .onChange(of: model.showArchivedCustomers) { _, _ in reload() }
        .onChange(of: model.revision) { _, _ in reload() }
        .sheet(item: $editing) { target in CustomerFormSheet(target: target).environmentObject(model) }
    }

    func reload() {
        guard let s = model.services else { return }
        customers = load { try s.customers.list(query: model.customerQuery, includeArchived: model.showArchivedCustomers) }
    }
}

enum CustomerFormTarget: Identifiable {
    case new
    case edit(Customer)
    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let c): return "edit-\(c.id ?? 0)"
        }
    }
}

struct CustomerFormSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let target: CustomerFormTarget
    @State private var input = CustomerInput()
    @State private var error: StoreError?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isNew ? "고객 등록" : "고객 정보 수정").font(.title3.weight(.semibold))
            Form {
                TextField("고객명 또는 업체명(필수)", text: $input.name)
                FieldError(message: error?.field == "name" ? error?.errorDescription : nil)
                TextField("담당자(선택)", text: $input.contactPerson)
                TextField("연락처(선택)", text: $input.phone)
                TextField("이메일(선택)", text: $input.email)
                FieldError(message: error?.field == "email" ? error?.errorDescription : nil)
                TextField("메모", text: $input.memo, axis: .vertical).lineLimit(2...5)
            }
            Text("연락처와 이메일은 선택 입력입니다. 이름이 같은 고객도 서로 다른 고객으로 등록됩니다.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button(isNew ? "등록" : "저장") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if case .edit(let c) = target { input = CustomerInput(c) }
        }
    }

    var isNew: Bool { if case .new = target { return true } else { return false } }

    func save() {
        guard let s = model.services else { return }
        do {
            switch target {
            case .new:
                let c = try s.customers.create(input)
                model.changed()
                dismiss()
                model.open(.customer(c.id!))
            case .edit(let c):
                try s.customers.update(c.id!, input)
                model.changed()
                dismiss()
            }
        } catch let e as StoreError {
            if e.field != nil { error = e } else { model.alert = AlertItem(title: "저장하지 못했습니다", message: e.errorDescription ?? "") }
        } catch {
            model.alert = AlertItem(title: "저장하지 못했습니다", message: error.localizedDescription)
        }
    }
}

// MARK: - 고객 상세: 제품, PC, 현재 라이선스, 전체 이력

struct CustomerDetailView: View {
    @EnvironmentObject var model: AppModel
    let customerId: Int64
    @State private var overview: LoadState<CustomerOverview> = .loading
    @State private var editing: CustomerFormTarget?
    @State private var addingPC = false
    @State private var linkingPC: CustomerPC?
    @State private var editingPC: CustomerPC?
    @State private var selected = Set<Int64>()
    @State private var showAllHistory = false

    var body: some View {
        LoadView(state: overview, retry: reload) { o in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(o.customer.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                        if o.customer.isArchived { StatusBadge(text: "보관", color: .gray) }
                        Spacer()
                        Button("정보 수정") { editing = .edit(o.customer) }
                        Button { addingPC = true } label: { Label("PC 등록", systemImage: "desktopcomputer") }
                        Button { model.issueMode = .new(customerId: customerId, pcId: nil, productId: nil) } label: {
                            Label("라이선스 발급", systemImage: "plus.rectangle.on.rectangle")
                        }
                        Menu("더 보기") {
                            Button("기존 라이선스 수동 등록…") { model.issueMode = .manual(customerId: customerId, pcId: nil, productId: nil) }
                            Button(o.customer.isArchived ? "보관 해제" : "보관") {
                                model.run { try model.services?.customers.setArchived(customerId, !o.customer.isArchived) }
                                model.changed()
                            }
                            Button("삭제(이력 없는 고객만)", role: .destructive) {
                                if model.run({ try model.services?.customers.delete(customerId) }) != nil {
                                    model.changed()
                                    model.paths[.customers] = NavigationPath()
                                }
                            }
                        }
                        .fixedSize()
                    }
                    GroupBox("고객 정보") {
                        VStack(alignment: .leading, spacing: 4) {
                            KeyValueRow(key: "담당자", value: o.customer.contactPerson)
                            KeyValueRow(key: "연락처", value: o.customer.phone)
                            KeyValueRow(key: "이메일", value: o.customer.email)
                            KeyValueRow(key: "메모", value: o.customer.memo)
                            KeyValueRow(key: "사용 제품", value: Array(Set(o.licenses.filter { $0.license.status == .issued }.map(\.productName))).sorted().joined(separator: ", "))
                        }
                        .padding(6)
                    }
                    GroupBox("PC (\(o.pcs.count))") {
                        if o.pcs.isEmpty {
                            Text("등록된 PC가 없습니다. 고객이 보낸 PC 번호를 'PC 등록'으로 추가하세요.").foregroundStyle(.secondary).padding(6)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(o.pcs) { pc in pcRow(pc, o) }
                            }
                            .padding(6)
                        }
                    }
                    GroupBox {
                        let current = o.licenses.filter { $0.license.status == .issued && $0.effective(now: Date()) != .expired }
                        let list = showAllHistory ? o.licenses : current
                        if list.isEmpty {
                            Text(showAllHistory ? "라이선스 이력이 없습니다." : "현재 사용 중이거나 사용 예정인 라이선스가 없습니다.").foregroundStyle(.secondary).padding(6)
                        } else {
                            LicenseTable(rows: list, selected: $selected).frame(minHeight: 160, idealHeight: CGFloat(60 + 28 * list.count), maxHeight: 420)
                        }
                    } label: {
                        HStack {
                            Text(showAllHistory ? "전체 라이선스 이력" : "현재 라이선스")
                            Picker("", selection: $showAllHistory) {
                                Text("현재").tag(false)
                                Text("전체 이력").tag(true)
                            }
                            .pickerStyle(.segmented).frame(width: 160)
                        }
                    }
                    GroupBox("변경 이력") { AuditList(logs: o.auditLogs).padding(6) }
                }
                .padding()
            }
        }
        .navigationTitle(title)
        .onAppear(perform: reload)
        .onChange(of: model.revision) { _, _ in reload() }
        .sheet(item: $editing) { t in CustomerFormSheet(target: t).environmentObject(model) }
        .sheet(isPresented: $addingPC) { PCFormSheet(customerId: customerId).environmentObject(model) }
        .sheet(item: $linkingPC) { pc in PCLinkSheet(pc: pc).environmentObject(model) }
        .sheet(item: $editingPC) { pc in PCEditSheet(pc: pc).environmentObject(model) }
    }

    var title: String {
        if case .loaded(let o) = overview { return o.customer.name }
        return "고객"
    }

    func reload() {
        guard let s = model.services else { return }
        overview = load { try s.queries.customerOverview(customerId) }
    }

    @ViewBuilder
    func pcRow(_ pc: CustomerPC, _ o: CustomerOverview) -> some View {
        let count = o.licenses.filter { $0.license.pcId == pc.id }.count
        let linked: [CustomerPC] = (try? model.services?.customers.linkedPCs(pc.id!)) ?? []
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                PCNumberText(scheme: pc.scheme, normalized: pc.numberNormalized)
                Text(pc.scheme.displayName).font(.caption).foregroundStyle(.secondary)
                if !pc.alias.isEmpty { Text("· \(pc.alias)").font(.callout) }
                Spacer()
                Text("라이선스 \(count)건").font(.caption).foregroundStyle(.secondary)
                Button("이 PC로 발급") { model.issueMode = .new(customerId: customerId, pcId: pc.id, productId: nil) }
                Menu("…") {
                    Button("별칭·메모 수정") { editingPC = pc }
                    Button("같은 PC의 다른 체계 번호 연결…") { linkingPC = pc }
                    Button("이 PC 라이선스 보기") {
                        model.licenseFilter = LicenseFilter(pcId: pc.id)
                        model.section = .licenses
                    }
                    Button("PC 삭제(라이선스 없는 PC만)", role: .destructive) {
                        if model.run({ try model.services?.customers.deletePC(pc.id!) }) != nil { model.changed() }
                    }
                    .disabled(count > 0)
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            if !linked.isEmpty {
                Text("같은 PC: " + linked.map { "\($0.scheme.displayName) \($0.displayNumber)" }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !pc.memo.isEmpty { Text(pc.memo).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

// MARK: - PC 등록·수정·연결

struct PCFormSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let customerId: Int64
    @State private var input = PCInput()
    @State private var schemeTouched = false
    @State private var check: PCCheck?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PC 등록").font(.title3.weight(.semibold))
            Text("고객 PC의 프로그램 화면에 표시된 번호를 그대로 붙여 넣으세요. 이 Mac의 하드웨어 번호는 수집하지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
            Form {
                TextField("PC 번호", text: $input.number)
                    .font(.body.monospaced())
                    .onChange(of: input.number) { _, v in
                        if !schemeTouched { input.scheme = PcScheme.suggest(for: v) }
                        recheck()
                    }
                Picker("번호 체계", selection: Binding(get: { input.scheme }, set: { input.scheme = $0; schemeTouched = true; recheck() })) {
                    ForEach(PcScheme.allCases) { s in Text(s.displayName).tag(s) }
                }
                Text("입력 모양으로 체계를 제안했습니다. 맞는지 확인하세요.").font(.caption).foregroundStyle(.secondary)
                if let c = check {
                    if c.isValid {
                        KeyValueRow(key: "저장될 값", value: c.display, monospaced: true)
                        if let e = c.existing {
                            FieldError(message: e.customerId == customerId
                                       ? "이 고객에게 이미 등록된 PC입니다."
                                       : "이미 다른 고객(\(c.existingOwnerName ?? "?"))에 등록된 PC입니다. 임의로 다시 배정하지 않습니다.")
                        }
                    } else {
                        FieldError(message: c.message)
                    }
                }
                TextField("PC 별칭(선택, 예: 사무실 PC)", text: $input.alias)
                TextField("메모", text: $input.memo)
                FieldError(message: error)
            }
            Text("PC 번호는 발급 이후 고칠 수 없습니다. 잘못 입력했거나 PC가 바뀌면 새 PC로 등록하고 재발급(PC 교체)하세요.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button("등록") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(check?.isValid ?? false) || check?.existing != nil)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    func recheck() {
        guard let s = model.services, !input.number.trimmingCharacters(in: .whitespaces).isEmpty else { check = nil; return }
        check = try? s.customers.check(scheme: input.scheme, number: input.number)
    }

    func save() {
        guard let s = model.services else { return }
        do {
            try s.customers.addPC(customerId: customerId, input)
            model.changed()
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct PCEditSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let pc: CustomerPC
    @State private var alias = ""
    @State private var memo = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PC 별칭·메모 수정").font(.title3.weight(.semibold))
            Text(pc.displayNumber).font(.body.monospaced()).textSelection(.enabled)
            TextField("별칭", text: $alias)
            TextField("메모", text: $memo, axis: .vertical).lineLimit(2...4)
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button("저장") {
                    if model.run({ try model.services?.customers.updatePC(pc.id!, alias: alias, memo: memo) }) != nil {
                        model.changed()
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { alias = pc.alias; memo = pc.memo }
    }
}

/// 같은 실제 PC의 다른 체계 번호를 수동으로 연결(이전 형식 고객이 새 버전 앱으로 옮겨 PC 번호가 바뀐 경우)
struct PCLinkSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let pc: CustomerPC
    @State private var candidates: [CustomerPC] = []
    @State private var linked: [CustomerPC] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("같은 PC의 다른 체계 번호").font(.title3.weight(.semibold))
            Text("\(pc.scheme.displayName): \(pc.displayNumber)").font(.callout.monospaced())
            if candidates.isEmpty {
                Text("이 고객에게 다른 체계로 등록된 PC가 없습니다. 먼저 다른 체계 번호를 PC로 등록하세요.").foregroundStyle(.secondary)
            }
            ForEach(candidates) { c in
                HStack {
                    Text("\(c.scheme.displayName) · \(c.displayNumber)").font(.callout.monospaced())
                    if !c.alias.isEmpty { Text(c.alias).foregroundStyle(.secondary) }
                    Spacer()
                    if linked.contains(where: { $0.id == c.id }) {
                        Button("연결 해제") { model.run { try model.services?.customers.unlinkPCs(pc.id!, c.id!) }; reload() }
                    } else {
                        Button("같은 PC로 연결") { model.run { try model.services?.customers.linkPCs(pc.id!, c.id!) }; reload() }
                    }
                }
            }
            HStack { Spacer(); Button("닫기") { model.changed(); dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear(perform: reload)
    }

    func reload() {
        guard let s = model.services else { return }
        candidates = ((try? s.customers.pcs(customerId: pc.customerId)) ?? []).filter { $0.id != pc.id && $0.scheme != pc.scheme }
        linked = (try? s.customers.linkedPCs(pc.id!)) ?? []
    }
}
