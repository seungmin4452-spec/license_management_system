import AppKit
import LicenseStore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // swift run 으로 실행해도 일반 앱처럼 앞에 나오게 한다
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.terminationReply() ?? .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct LicenseManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("라이선스 관리") {
            RootView()
                .environmentObject(model)
                .environment(\.locale, Locale(identifier: "ko_KR"))
                .frame(minWidth: 1100, minHeight: 700)
                .onAppear { delegate.model = model }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("라이선스 발급…") { model.issueMode = .new(customerId: nil, pcId: nil, productId: nil) }
                    .keyboardShortcut("n", modifiers: [.command])
                    .disabled(model.services == nil)
            }
        }
    }
}
