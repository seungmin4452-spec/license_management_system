// swift-tools-version:6.0
// 라이선스 관리 프로그램 (판매자용 macOS 앱)
//
// 대상: macOS 14 이상, Xcode 16 이상(Swift 6 도구). 언어 모드는 Swift 5(엄격한 동시성 검사 완화).
// 의존성: GRDB.swift 7.x (SQLite). 처음 빌드하면 Package.resolved가 생기므로 함께 커밋해 버전을 고정한다.
//
// 구성
//   LicenseCore     : 라이선스 형식·생성기·서명·검증 (UI·DB와 무관한 순수 코드, CryptoKit)
//   LicenseStore    : SQLite 저장소, 업무 규칙(발급·갱신·교체·취소), CSV, 백업, 키체인
//   LicenseManager  : SwiftUI 앱(실행 파일)
import PackageDescription

let package = Package(
    name: "LicenseManager",
    defaultLocalization: "ko",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LicenseManager", targets: ["LicenseManager"]),
        .library(name: "LicenseCore", targets: ["LicenseCore"]),
        .library(name: "LicenseStore", targets: ["LicenseStore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.4.0"),
    ],
    targets: [
        .target(
            name: "LicenseCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "LicenseStore",
            dependencies: ["LicenseCore", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "LicenseManager",
            dependencies: ["LicenseCore", "LicenseStore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "LicenseCoreTests",
            dependencies: ["LicenseCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "LicenseStoreTests",
            dependencies: ["LicenseCore", "LicenseStore", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
