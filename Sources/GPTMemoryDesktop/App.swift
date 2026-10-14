import SwiftUI
import AppKit

final class ManagerAppDelegate: NSObject, NSApplicationDelegate {
    var reportLibrary: AIReportLibraryModel?
    var sessionManagement: SessionManagementModel?
    var memoryModel: DesktopModel?
    private var terminationTask: Task<Void, Never>?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let library = reportLibrary
        let management = sessionManagement
        let memory = memoryModel
        let prompts = memory?.aiModel.promptLibrary
        guard library?.isSaving == true || library?.isRemoving == true || library?.isExporting == true
                || management?.isSaving == true || memory?.processActions.hasPendingWork == true
                || memory?.isFileOperationInProgress == true || prompts?.isSaving == true || memory?.knowledgeModel.isSaving == true else { return .terminateNow }
        // A completed AI response can still be queued for local persistence.
        // Let that bounded file operation finish before quitting the process.
        if terminationTask == nil {
            terminationTask = Task { @MainActor [weak self] in
                while library?.isSaving == true || library?.isRemoving == true || library?.isExporting == true
                        || management?.isSaving == true || memory?.processActions.hasPendingWork == true
                        || memory?.isFileOperationInProgress == true || prompts?.isSaving == true || memory?.knowledgeModel.isSaving == true {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                self?.terminationTask = nil
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}

@main
struct GPTManagerApp: App {
    @NSApplicationDelegateAdaptor(ManagerAppDelegate.self) private var delegate
    @StateObject private var model = DesktopModel()

    var body: some Scene {
        WindowGroup("GPT Manager") {
            MemoryDesktopView(model: model)
                .frame(minWidth: 1000, minHeight: 680)
                .onAppear {
                    delegate.reportLibrary = model.aiModel.reportLibrary
                    delegate.sessionManagement = model.sessionModel.management
                    delegate.memoryModel = model
                    model.startMonitoring()
                }
                .onDisappear { model.stopMonitoring() }
        }
        .defaultSize(width: 1160, height: 790)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button(model.isKnowledgeWorkspaceActive ? "刷新记忆库" : (model.isReportLibraryActive ? "刷新 AI 报告" : (model.isSessionWorkspaceActive ? "刷新 Codex 会话" : "刷新内存数据"))) { model.refreshCurrentPage() }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(!model.isKnowledgeWorkspaceActive && !model.isSessionWorkspaceActive && !model.isReportLibraryActive && model.isBusy)
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
