import SwiftUI
import AppKit

@main
struct MyMemoGuidedApp: App {
    @NSApplicationDelegateAdaptor(GuidedDelegate.self) var delegate
    @StateObject private var model = AppModel()
    private var displayName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "MyMemo" }
    var body: some Scene {
        Window(displayName, id: "main") {
            GuidedRootView(model: model).frame(minWidth: 1050, minHeight: 760)
                .preferredColorScheme(.light).tint(MemoStyle.green).onAppear { model.start() }
        }.defaultSize(width: 1140, height: 820)
        MenuBarExtra(displayName, systemImage: "waveform.badge.plus") { GuidedMenu(model: model) }
    }
}
private struct GuidedMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "MyMemo")
        Text(model.preferences.completed ? model.activity : "还有几步设置等待完成")
        Divider()
        Button("打开 MyMemo") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        if model.preferences.completed {
            Button(model.paused ? "继续整理录音" : "暂停自动整理") { model.togglePause() }
        }
        Divider()
        Button("退出 MyMemo") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
final class GuidedDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        sender.windows.first?.makeKeyAndOrderFront(nil); return true
    }
}
