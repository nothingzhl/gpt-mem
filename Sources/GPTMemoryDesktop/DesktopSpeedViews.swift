import SwiftUI
import Charts
import GPTSessionKit

struct DesktopSpeedHost: View, Equatable {
    let model: DesktopSpeedModel
    static func == (a: Self, b: Self) -> Bool { a.model === b.model }
    var body: some View { DesktopSpeedView(model: model) }
}
struct DesktopSpeedView: View {
    @ObservedObject var model: DesktopSpeedModel
    @State private var selectedModel = ""
    private var rows: [DesktopSpeedSample] { model.snapshot.samples.filter { selectedModel.isEmpty || $0.model == selectedModel } }
    private func median(_ values: [Double]) -> Double? {
        let sorted = values.sorted(); guard !sorted.isEmpty else { return nil }
        return sorted.count % 2 == 0 ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2 : sorted[sorted.count / 2]
    }
    private func number(_ value: Double?, suffix: String) -> String { value.map { String(format: "%.1f", $0) + suffix } ?? "未记录" }
    var body: some View {
        let rows = self.rows
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("日志模型", selection: $selectedModel) {
                    Text("全部模型").tag("")
                    ForEach(Array(Set(model.snapshot.samples.map(\.model))).sorted(), id: \.self) { Text($0).tag($0) }
                    if !selectedModel.isEmpty && !model.snapshot.samples.contains(where: { $0.model == selectedModel }) { Text(selectedModel + "（暂无区间）").tag(selectedModel) }
                }.frame(width: 310)
                Spacer()
                if model.isRefreshing { ProgressView().controlSize(.small) }
                Button("刷新") { Task { await model.refresh() } }.disabled(model.isRefreshing)
                Button(model.isMonitoring ? "暂停监听" : "开始监听") { model.isMonitoring ? model.stop() : model.start() }
            }
            Text("只读监听来源明确为 Codex Desktop／ChatGPT Desktop 的本地会话日志，不额外调用模型、不读取凭据、不拦截网络、不存储聊天正文。普通 ChatGPT 云端会话暂不在本适配器范围中。").font(.caption).foregroundStyle(.secondary)
            Text("日志目录：" + model.root.appendingPathComponent("sessions").path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            Text("下方 Token/s 是两次用量记录之间的端到端输出效率，包含工具、网络、思考和调度等待，也受日志写入延迟影响；不是模型纯生成速度。模型名来自日志，无法核验服务端实际路由。输出字段可能包含工具调用参数和思考，并不等于屏幕可见文字；思考字段单列，不重复加总。").font(.caption).foregroundStyle(.orange)
            HStack(spacing: 10) {
                metric("区间输出效率中位数", number(median(rows.map(\.intervalRate)), suffix: " Token/s"))
                metric("首段用量等待中位数", number(median(rows.filter(\.firstInTurn).map(\.seconds)), suffix: " 秒"))
                metric("真实首字时间", "未记录")
                metric("纯生成 Token/s", "未记录")
            }
            HStack {
                Text("最近 48 小时 · \(rows.count) 条有效区间 · \(model.snapshot.files) 个候选日志").font(.caption)
                if let updated = model.updatedAt { Text("扫描于 " + updated.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary) }
                if model.snapshot.pendingFiles > 0 { Text("\(model.snapshot.pendingFiles) 个文件待继续读取（尚未追上最新记录）").font(.caption).foregroundStyle(.orange) }
            }
            if let error = model.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if !model.snapshot.warnings.isEmpty {
                DisclosureGroup("数据范围与读取提示") { Text(model.snapshot.warnings.joined(separator: "\n")).font(.caption).textSelection(.enabled) }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if rows.isEmpty {
                        Text(model.isRefreshing ? "正在读取本地用量记录…" : "还没有可计算的桌面用量区间").font(.title3)
                        Text("在桌面 Codex 会话中正常使用即可；如日志尚未追上，保持本页打开会继续增量读取。不会额外发测速请求。用量和时间缺失时不伪造速度。").foregroundStyle(.secondary)
                    } else {
                        Text("区间输出效率趋势（最近 120 条）").font(.headline)
                        Chart(Array(rows.prefix(120).reversed())) { sample in
                            PointMark(x: .value("用量记录时间", sample.end), y: .value("区间 Token/s", sample.intervalRate))
                                .foregroundStyle(by: .value("日志模型", sample.model))
                        }.frame(height: 180)
                        Text("模型对比（真实使用条件各异，不是同提示词基准测试）").font(.headline)
                        ForEach(Array(Set(rows.map(\.model))).sorted(), id: \.self) { name in
                            let matching = rows.filter { $0.model == name }
                            HStack {
                                Text(name).frame(maxWidth: .infinity, alignment: .leading)
                                Text("\(matching.count) 段")
                                Text(number(median(matching.map(\.intervalRate)), suffix: " Token/s")).frame(width: 150, alignment: .trailing)
                                Text("区间耗时 " + number(median(matching.map(\.seconds)), suffix: " 秒")).frame(width: 170, alignment: .trailing)
                            }.font(.caption)
                        }
                        Text("最近区间（最多展示 100 条）").font(.headline)
                        ForEach(rows.prefix(100)) { sample in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(sample.model).fontWeight(.medium)
                                    Spacer()
                                    Text(number(sample.intervalRate, suffix: " Token/s")).fontWeight(.semibold)
                                }
                                Text("\(sample.end.formatted()) · \(sample.firstInTurn ? "首段记录" : "后续记录") · 区间 \(number(sample.seconds, suffix: " 秒")) · 输出 \(sample.output) · 思考字段 \(sample.reasoning.map(String.init) ?? "未记录")").font(.caption).foregroundStyle(.secondary)
                                Text("会话 " + sample.sessionID).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            }.padding(10).background(MemoryStyle.surface).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.onAppear { model.start() }.onDisappear { model.stop() }
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.system(size: 18, weight: .semibold)) }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(MemoryStyle.surface).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
