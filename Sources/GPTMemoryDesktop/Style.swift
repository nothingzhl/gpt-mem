import SwiftUI
import AppKit
import GPTMemoryCore

enum MemoryStyle {
    private static func color(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                           green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        })
    }

    static let background = color(0xf7f7fa, 0x17191f)
    static let sidebar = color(0xfafafd, 0x1b1d25)
    static let surface = color(0xffffff, 0x232630)
    static let border = color(0xe9e9ef, 0x343843)
    static let text = color(0x242633, 0xebedf3)
    static let secondary = color(0x818694, 0x989eae)
    static let accent = color(0x6266eb, 0x989aff)
    static let accentBackground = color(0xeeeefe, 0x30324e)
    static let green = color(0x24a57c, 0x63d5af)
    static let orange = color(0xd58c38, 0xecc07a)
    static let red = color(0xcb6471, 0xf3939f)

    static func roleColor(_ role: ProcessRole) -> Color {
        switch role {
        case .renderer: return Color(red: 0.39, green: 0.45, blue: 0.94)
        case .gpu: return Color(red: 0.80, green: 0.58, blue: 0.92)
        case .appMain, .appService: return Color(red: 0.37, green: 0.65, blue: 0.84)
        case .codexBackend: return Color(red: 0.31, green: 0.73, blue: 0.69)
        case .mcpApp, .mcpCodeReview, .mcpMySQL, .mcpCUA: return Color(red: 0.86, green: 0.62, blue: 0.40)
        case .repl, .toolWorker: return Color(red: 0.62, green: 0.62, blue: 0.82)
        default: return MemoryStyle.secondary
        }
    }
}

struct MemoryCard<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.padding(20)
            .background(MemoryStyle.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(MemoryStyle.border, lineWidth: 1))
    }
}

/// The entire header, including its trailing space, toggles the disclosure.
/// Content stays outside the button so links and text selection remain independent.
struct WideDisclosureGroupStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 12).accessibilityHidden(true)
                    configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "已展开" : "已收起")
            .help(configuration.isExpanded ? "点击整行收起" : "点击整行展开")
            if configuration.isExpanded {
                configuration.content.padding(.top, 6)
            }
        }
    }
}

struct MemorySectionTitle: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(MemoryStyle.text)
            if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary) }
        }
    }
}

struct MemoryEmptyState: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 28, weight: .light)).foregroundStyle(MemoryStyle.accent.opacity(0.65))
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(MemoryStyle.text)
            Text(detail).font(.system(size: 12)).foregroundStyle(MemoryStyle.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 410)
        }.frame(maxWidth: .infinity).padding(.vertical, 40)
    }
}

struct MemoryBadge: View {
    let text: String
    var color: Color = MemoryStyle.accent
    var body: some View {
        Text(text).font(.system(size: 10, weight: .medium))
            .foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.1)).clipShape(Capsule())
    }
}

struct MemoryMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let icon: String
    var color: Color = MemoryStyle.accent
    var body: some View {
        MemoryCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(title).font(.system(size: 12)).foregroundStyle(MemoryStyle.secondary)
                    Spacer(minLength: 4)
                    Image(systemName: icon).font(.system(size: 12)).foregroundStyle(color)
                        .frame(width: 28, height: 28).background(color.opacity(0.09))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Text(value).font(.system(size: 27, weight: .semibold, design: .rounded))
                    .foregroundStyle(MemoryStyle.text).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                Text(detail).font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                    .lineLimit(2).frame(minHeight: 26, alignment: .topLeading)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

enum MemoryFormat {
    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = format
        return formatter
    }
    private static let timeFormatter = formatter("HH:mm:ss")
    private static let dateFormatter = formatter("MM-dd HH:mm:ss")
    private static let fullDateFormatter = formatter("yyyy-MM-dd HH:mm:ss")
    static func bytes(_ bytes: UInt64) -> String {
        if bytes >= 1_073_741_824 { return String(format: "%.2f GiB", Double(bytes) / 1_073_741_824) }
        return String(format: "%.1f MiB", Double(bytes) / 1_048_576)
    }
    static func delta(_ bytes: Int64) -> String { String(format: "%+.1f MiB", Double(bytes) / 1_048_576) }
    static func executable(_ value: String) -> String { URL(fileURLWithPath: value).lastPathComponent }
    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }
    static func date(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }
    static func fullDate(_ date: Date) -> String {
        fullDateFormatter.string(from: date)
    }
    static func pressure(_ value: Int?) -> String {
        switch value {
        case 1: return "正常"
        case 2: return "警告"
        case 4: return "严重"
        case nil: return "未知"
        default: return "级别 \(value!)"
        }
    }
    static func pressureColor(_ value: Int?) -> Color {
        switch value {
        case 1: return MemoryStyle.green
        case 2: return MemoryStyle.orange
        case 4: return MemoryStyle.red
        default: return MemoryStyle.secondary
        }
    }
}
