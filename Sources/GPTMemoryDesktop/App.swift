import SwiftUI
import AppKit

final class ManagerAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct GPTManagerApp: App {
    @NSApplicationDelegateAdaptor(ManagerAppDelegate.self) private var delegate
    @StateObject private var model = DesktopModel()

    var body: some Scene {
        WindowGroup("GPT Manager") {
            MemoryDesktopView(model: model)
                .frame(minWidth: 1000, minHeight: 680)
                .onAppear { model.startMonitoring() }
                .onDisappear { model.stopMonitoring() }
        }
        .defaultSize(width: 1160, height: 790)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button(model.isSessionWorkspaceActive ? "刷新 Codex 会话" : "刷新内存数据") { model.refreshCurrentPage() }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(!model.isSessionWorkspaceActive && model.isBusy)
                Button(model.isMonitoring ? "暂停采集" : "开始采集") {
                    model.isMonitoring ? model.stopMonitoring() : model.startMonitoring()
                }.keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(model.isBusy || model.modeLabel.contains("外部采集"))
                Button("导出内存报告…") { model.exportReport() }.keyboardShortcut("e", modifiers: [.command])
                    .disabled(model.isBusy || (model.analysis?.sampleCount ?? 0) < 2)
            }
        }
    }
}
