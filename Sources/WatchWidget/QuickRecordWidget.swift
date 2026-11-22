import SwiftUI
import WidgetKit

private struct QuickRecordEntry: TimelineEntry {
    let date: Date
}

private struct QuickRecordProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickRecordEntry {
        QuickRecordEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickRecordEntry) -> Void) {
        completion(QuickRecordEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickRecordEntry>) -> Void) {
        completion(Timeline(entries: [QuickRecordEntry(date: Date())], policy: .never))
    }
}

private struct QuickRecordWidgetView: View {
    @Environment(\.widgetFamily) private var family

    private let accent = Color(red: 1.00, green: 0.18, blue: 0.27)

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Label("全天录音 · 一键开始", systemImage: "record.circle")
            case .accessoryRectangular:
                HStack(spacing: 9) {
                    recordIcon
                    VStack(alignment: .leading, spacing: 1) {
                        Text("全天录音")
                            .font(.headline.weight(.bold))
                        Text("轻点立即安全录制")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            default:
                recordIcon
            }
        }
        .widgetURL(AppRoute.quickRecordURL)
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [accent.opacity(0.20), Color.black.opacity(0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .accessibilityLabel("打开全天录音并立即开始")
    }

    private var recordIcon: some View {
        ZStack {
            Circle()
                .stroke(accent.opacity(0.52), lineWidth: 2)
            Circle()
                .fill(
                    LinearGradient(
                        colors: [accent, Color(red: 0.72, green: 0.02, blue: 0.10)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .padding(5)
            Image(systemName: "mic.fill")
                .font(.caption.bold())
                .foregroundStyle(.white)
        }
        .widgetAccentable()
    }
}

private struct QuickRecordWidget: Widget {
    let kind = "QuickRecordWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuickRecordProvider()) { _ in
            QuickRecordWidgetView()
        }
        .configurationDisplayName("一键录音")
        .description("从表盘打开全天录音并自动开始。")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct QuickRecordWidgetBundle: WidgetBundle {
    var body: some Widget {
        QuickRecordWidget()
    }
}
