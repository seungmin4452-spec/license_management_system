import LicenseCore
import LicenseStore
import SwiftUI
import UniformTypeIdentifiers

struct ProductsView: View {
    @EnvironmentObject var model: AppModel
    @State private var products: LoadState<[Product]> = .loading
    @State private var creating = false
    @State private var selected = Set<Int64>()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("제품마다 라이선스 생성 방식과 서명 키를 설정합니다.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("기존 제품(ReviewCut·RentalDesk) 설정 추가") { addKnown() }
                    .help("이미 판매한 두 제품을 고객 앱 공개키와 함께 등록합니다. 비밀키는 제품 화면에서 따로 가져옵니다.")
                Button { creating = true } label: { Label("제품 등록", systemImage: "plus") }
            }
            .padding(10)
            Divider()
            LoadView(state: products, retry: reload) { list in
                if list.isEmpty {
                    EmptyStateView(symbol: "shippingbox", title: "등록된 제품이 없습니다",
                                   message: "'기존 제품 설정 추가' 또는 '제품 등록'으로 시작하세요.")
                } else {
                    Table(list, selection: $selected) {
                        TableColumn("제품명") { p in
                            HStack {
                                Text(p.name)
                                if p.isArchived { StatusBadge(text: "보관", color: .gray) }
                                else if !p.isActive { StatusBadge(text: "판매 중지", color: .orange) }
                            }
                        }
                        TableColumn("제품 코드") { p in Text(p.code).font(.body.monospaced()) }
                        TableColumn("공통 형식 코드") { p in Text(p.v1ProductCode ?? "—").font(.body.monospaced()) }
                        TableColumn("기본 기간") { p in Text(p.defaultTermMonths.map { "\($0)개월" } ?? "영구") }
                        TableColumn("설명") { p in Text(p.description).lineLimit(1) }
                    }
                    .contextMenu(forSelectionType: Int64.self) { _ in } primaryAction: { ids in
                        if let id = ids.first { model.open(.product(id)) }
                    }
                }
            }
        }
        .navigationTitle("제품")
        .onAppear(perform: reload)
        .onChange(of: model.revision) { _, _ in reload() }
        .sheet(isPresented: $creating) { ProductFormSheet(productId: nil).environmentObject(model) }
    }

    func reload() {
        guard let s = model.services else { return }
        products = load { try s.products.list() }
    }

    func addKnown() {
        guard let s = model.services else { return }
        if let created = model.run({ try s.products.addKnownProducts() }) {
            model.changed()
            model.alert = AlertItem(
                title: created.isEmpty ? "이미 등록되어 있습니다" : "\(created.map(\.name).joined(separator: ", ")) 설정을 추가했습니다",
                message: "자동 발급하려면 제품 화면에서 '기존 비밀키 가져오기'로 서명 키를 가져오세요. 가져온 키는 고객 앱 공개키와 같은지 확인합니다.")
        }
    }
}

// MARK: - 제품 등록·수정

struct ProductFormSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let productId: Int64?
    @State private var input = ProductInput()
    @State private var error: StoreError?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(productId == nil ? "제품 등록" : "제품 수정").font(.title3.weight(.semibold))
            Form {
                TextField("제품명", text: $input.name)
                fieldError("name")
                TextField("제품 코드(관리용, 고유)", text: $input.code)
                fieldError("code")
                TextField("설명", text: $input.description)
                Toggle("판매 중", isOn: $input.isActive)
                Section("라이선스 생성 방식(여러 개 선택 가능)") {
                    ForEach(GeneratorID.allCases) { g in
                        Toggle(isOn: Binding(get: { input.generators.contains(g) },
                                             set: { on in if on { input.generators.insert(g) } else { input.generators.remove(g) } })) {
                            VStack(alignment: .leading) {
                                Text(g.displayName)
                                Text(generatorHint(g)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    fieldError("generators")
                }
                Section("공통 형식 설정") {
                    TextField("공통 형식 제품 코드(예: REVIEWCUT)", text: $input.v1ProductCode).font(.body.monospaced())
                    fieldError("v1ProductCode")
                    TextField("기본 에디션(예: standard, full)", text: $input.defaultEdition)
                    fieldError("defaultEdition")
                    TextField("기본 사용 가능 최고 버전(예: 1.0, 비우면 제한 없음)", text: $input.defaultMaxVersion)
                    fieldError("defaultMaxVersion")
                }
                Section("기본 유효기간") {
                    Stepper(value: $input.defaultTermMonths, in: 0...120) {
                        Text(input.defaultTermMonths == 0 ? "영구" : "\(input.defaultTermMonths)개월(시작일 + N개월 같은 날짜까지)")
                    }
                    Text("발급할 때 바꿀 수 있습니다.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Text("제품 코드나 생성 방식을 바꿔도 이미 발급한 기록(발급 당시 조건)은 바뀌지 않습니다.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button(productId == nil ? "등록" : "저장") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 680)
        .onAppear {
            guard !loaded, let id = productId, let s = model.services else { return }
            loaded = true
            if let d = try? s.products.detail(id) { input = ProductInput(product: d.product, generators: d.generators) }
        }
    }

    func fieldError(_ field: String) -> FieldError {
        FieldError(message: error?.field == field ? error?.errorDescription : nil)
    }

    func generatorHint(_ g: GeneratorID) -> String {
        switch g {
        case .lmsLicenseV1: return "모든 새 제품의 기본. 25자 공통 PC 번호. 영구·기간제·미래 시작 지원"
        case .reviewcutLegacy: return "ReviewCut 0.1.0 앱용. 설치 ID(VRN-). 영구만"
        case .rentaldeskLegacy: return "RentalDesk 1.0.0 앱용. 20자 기기 코드. 미래 시작 불가"
        case .manual: return "생성 방식이 없는 외부 라이선스를 수동 등록해 관리"
        }
    }

    func save() {
        guard let s = model.services else { return }
        do {
            if let id = productId { try s.products.update(id, input) } else {
                let p = try s.products.create(input)
                dismiss()
                model.changed()
                model.open(.product(p.id!))
                return
            }
            model.changed()
            dismiss()
        } catch let e as StoreError where e.field != nil {
            error = e
        } catch {
            model.alert = AlertItem(title: "저장하지 못했습니다", message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

// MARK: - 제품 상세 + 서명 키

struct ProductDetailView: View {
    @EnvironmentObject var model: AppModel
    let productId: Int64
    @State private var detail: LoadState<ProductDetail> = .loading
    @State private var keys: [SigningKeyInfo] = []
    @State private var editing = false
    @State private var keySheet: KeySheet?
    @State private var exportKey: SigningKey?

    enum KeySheet: String, Identifiable {
        case generate, importSecret, registerPublic
        var id: String { rawValue }
    }

    var body: some View {
        LoadView(state: detail, retry: reload) { d in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(d.product.name).font(.title2.weight(.semibold))
                        if d.product.isArchived { StatusBadge(text: "보관", color: .gray) }
                        else if !d.product.isActive { StatusBadge(text: "판매 중지", color: .orange) }
                        Spacer()
                        Button("수정") { editing = true }
                        Button(d.product.isArchived ? "보관 해제" : "보관") {
                            model.run { try model.services?.products.setArchived(productId, !d.product.isArchived) }
                            model.changed()
                        }
                        Button("삭제", role: .destructive) {
                            if model.run({ try model.services?.products.delete(productId) }) != nil {
                                model.changed()
                                model.paths[.products] = NavigationPath()
                            }
                        }
                        .disabled(d.licenseCount > 0 || !d.keys.isEmpty)
                        .help("라이선스나 서명 키가 있는 제품은 삭제하지 않고 보관합니다.")
                    }
                    GroupBox("설정") {
                        VStack(alignment: .leading, spacing: 4) {
                            KeyValueRow(key: "제품 코드", value: d.product.code, monospaced: true)
                            KeyValueRow(key: "설명", value: d.product.description)
                            KeyValueRow(key: "생성 방식", value: d.enabledGenerators.map(\.displayName).joined(separator: ", "))
                            KeyValueRow(key: "공통 형식 제품 코드", value: d.product.v1ProductCode ?? "", monospaced: true, copyable: true)
                            KeyValueRow(key: "기본 에디션", value: d.product.defaultEdition)
                            KeyValueRow(key: "기본 최고 버전", value: d.product.defaultMaxVersion ?? "제한 없음")
                            KeyValueRow(key: "기본 기간", value: d.product.defaultTermMonths.map { "\($0)개월" } ?? "영구")
                            KeyValueRow(key: "발급 기록", value: "\(d.licenseCount)건")
                        }
                        .padding(6)
                    }
                    GroupBox {
                        keysSection(d)
                    } label: {
                        HStack {
                            Text("서명 키")
                            Spacer()
                            Menu("키 추가") {
                                Button("기존 비밀키 가져오기…") { keySheet = .importSecret }
                                Button("고객 앱 공개키만 등록…") { keySheet = .registerPublic }
                                Divider()
                                Button("새 키 쌍 만들기(새 제품용)…") { keySheet = .generate }
                            }
                            .fixedSize()
                        }
                    }
                }
                .padding()
            }
        }
        .navigationTitle(title)
        .onAppear(perform: reload)
        .onChange(of: model.revision) { _, _ in reload() }
        .sheet(isPresented: $editing) { ProductFormSheet(productId: productId).environmentObject(model) }
        .sheet(item: $keySheet) { kind in
            if case .loaded(let d) = detail {
                KeySheetView(kind: kind, product: d.product, existing: d.keys).environmentObject(model)
            }
        }
        .confirmationDialog("비밀키를 파일로 내보낼까요?", isPresented: Binding(get: { exportKey != nil }, set: { if !$0 { exportKey = nil } }),
                            presenting: exportKey) { key in
            Button("내보내기(권한 600 파일)", role: .destructive) { export(key) }
        } message: { key in
            Text("비밀키(\(key.keyId))를 가진 사람은 이 제품의 라이선스를 마음대로 만들 수 있습니다. 오프라인 백업용으로만, 저장소·클라우드 동기화 폴더가 아닌 안전한 곳에 보관하세요.")
        }
    }

    var title: String {
        if case .loaded(let d) = detail { return d.product.name }
        return "제품"
    }

    func reload() {
        guard let s = model.services else { return }
        detail = load { try s.products.detail(productId) }
        keys = (try? s.products.keyInfos(productId: productId)) ?? []
    }

    @ViewBuilder
    func keysSection(_ d: ProductDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("비밀키는 이 Mac의 키체인에만 저장됩니다(DB·백업·로그에 넣지 않음). 다른 Mac에서 복원했다면 비밀키를 다시 가져와야 자동 발급할 수 있습니다.")
                .font(.caption).foregroundStyle(.secondary)
            if keys.isEmpty {
                Text("서명 키가 없습니다. 이미 판매한 제품은 '기존 비밀키 가져오기', 새 제품은 '새 키 쌍 만들기'를 쓰세요.")
                    .foregroundStyle(.secondary)
            }
            ForEach(keys) { info in
                let k = info.key
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(k.keyId).font(.headline.monospaced())
                        StatusBadge(text: k.status.displayName, color: k.status == .active ? .green : .gray)
                        StatusBadge(text: k.origin.displayName, color: .blue)
                        StatusBadge(text: info.hasSecret ? "비밀키 있음(키체인)" : "비밀키 없음", color: info.hasSecret ? .teal : .orange)
                        Spacer()
                        Button("key_id 복사") { model.copy(k.keyId) }
                        Button("공개키(hex) 복사") { model.copy(k.publicKeyHex) }
                        Button("공개키(PEM) 복사") { model.copy(k.publicKeyPEM) }
                        Menu("…") {
                            Button(k.status == .active ? "보관(발급에 쓰지 않음)" : "다시 사용") {
                                model.run { try model.services?.products.setKeyStatus(k.id!, k.status == .active ? .archived : .active) }
                                model.changed()
                            }
                            Button("비밀키 내보내기(오프라인 백업)…") { exportKey = k }.disabled(!info.hasSecret)
                        }
                        .fixedSize()
                    }
                    Text(k.publicKeyHex).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
                }
                .padding(8)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            }
            DisclosureGroup("고객 앱에 공개키 넣는 방법") {
                Text("""
                새 제품의 고객 앱에는 (key_id, 공개키) 목록만 넣습니다. 비밀키는 넣지 않습니다.
                • 공통 형식 v1: 검증 시 파일의 key_id로 공개키를 고릅니다. 앱의 제품 코드는 '공통 형식 제품 코드'와 같아야 합니다.
                • 공개키 표기는 앱 편의대로(hex 또는 SPKI PEM). 예) TypeScript: createPublicKey(PEM), Python: VerifyKey(bytes.fromhex(hex))
                • 키를 교체할 때는 이전 공개키를 앱에 남겨 두어야 기존 라이선스가 계속 인정됩니다.
                """)
                .font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(6)
    }

    func export(_ key: SigningKey) {
        guard let url = FilePanels.save(name: "\(key.keyId).private.pem", types: [FilePanels.pem],
                                        message: "비밀키를 저장합니다. 파일 권한은 600(본인만 읽기)으로 설정됩니다.") else { return }
        if model.run("내보내지 못했습니다", { try model.services?.products.exportPrivateKey(keyRowId: key.id!, to: url) }) != nil {
            model.alert = AlertItem(title: "비밀키를 저장했습니다", message: "\(url.path)\n안전한 곳에 보관한 뒤 필요 없으면 삭제하세요.")
        }
    }
}

struct KeySheetView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let kind: ProductDetailView.KeySheet
    let product: Product
    let existing: [SigningKey]
    @State private var keyId = ""
    @State private var expected = ""
    @State private var publicKey = ""
    @State private var fileData: Data?
    @State private var fileName = ""
    @State private var error: String?

    var known: KnownCustomerAppKeys.Entry? {
        KnownCustomerAppKeys.all.first { $0.v1ProductCode == product.v1ProductCode }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch kind {
            case .generate:
                Text("새 키 쌍 만들기").font(.title3.weight(.semibold))
                Label("이미 판매한 제품에는 새 키를 만들지 마세요. 배포된 앱은 새 키로 서명한 라이선스를 인정하지 않습니다. 기존 제품은 '기존 비밀키 가져오기'를 쓰세요.",
                      systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                TextField("key_id(예: \(product.code.lowercased())-2026)", text: $keyId).font(.body.monospaced())
                Text("만든 뒤 공개키(hex 또는 PEM)와 key_id를 복사해 고객 앱에 넣으세요.").font(.caption).foregroundStyle(.secondary)
            case .importSecret:
                Text("기존 비밀키 가져오기").font(.title3.weight(.semibold))
                if let k = known {
                    Text("\(k.productName) 비밀키 위치: \(k.hint)").font(.callout)
                }
                TextField("key_id", text: $keyId).font(.body.monospaced())
                HStack {
                    Button("비밀키 파일 선택…") { pick() }
                    Text(fileName.isEmpty ? "선택한 파일 없음" : fileName).foregroundStyle(.secondary)
                }
                Text("지원 형식: PKCS#8 PEM(ReviewCut), JSON의 private_key_hex(RentalDesk), seed hex 64자리").font(.caption).foregroundStyle(.secondary)
                TextField("확인용 공개키(고객 앱에 들어 있는 값, hex 또는 PEM)", text: $expected, axis: .vertical).lineLimit(1...4).font(.caption.monospaced())
                Text("가져온 비밀키의 공개키가 이 값(또는 이미 등록된 같은 key_id의 공개키, 알려진 고객 앱 공개키)과 다르면 거부합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            case .registerPublic:
                Text("고객 앱 공개키만 등록").font(.title3.weight(.semibold))
                Text("비밀키 없이 공개키만 등록하면 수동 등록 파일의 서명을 확인할 수 있고, 나중에 비밀키를 가져올 때 대조합니다.")
                    .font(.callout)
                TextField("key_id", text: $keyId).font(.body.monospaced())
                TextField("공개키(hex 64자리 또는 SPKI PEM)", text: $publicKey, axis: .vertical).lineLimit(1...4).font(.caption.monospaced())
            }
            FieldError(message: error)
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button(actionTitle) { submit() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            if let k = known {
                keyId = k.keyId
                if kind == .registerPublic { publicKey = k.publicKeyHex }
                if kind == .importSecret && !existing.contains(where: { $0.keyId == k.keyId }) { expected = k.publicKeyHex }
            }
        }
    }

    var actionTitle: String {
        switch kind {
        case .generate: return "만들기"
        case .importSecret: return "가져오기"
        case .registerPublic: return "등록"
        }
    }

    func pick() {
        guard let url = FilePanels.open(types: [FilePanels.pem, .json, .plainText, .data], message: "서명 비밀키 파일을 고르세요").first else { return }
        do {
            fileData = try Data(contentsOf: url)
            fileName = url.lastPathComponent
        } catch {
            self.error = "파일을 읽을 수 없습니다."
        }
    }

    func submit() {
        guard let s = model.services else { return }
        do {
            switch kind {
            case .generate:
                try s.products.generateKey(productId: product.id!, keyId: keyId)
            case .importSecret:
                guard let data = fileData else { error = "비밀키 파일을 고르세요."; return }
                try s.products.importKey(productId: product.id!, keyId: keyId, fileContents: data, expectedPublicKey: expected)
                fileData = nil
            case .registerPublic:
                try s.products.registerExpectedPublicKey(productId: product.id!, keyId: keyId, publicKey: publicKey)
            }
            model.changed()
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
