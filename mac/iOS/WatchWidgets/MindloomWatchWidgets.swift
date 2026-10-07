import AppIntents
import SwiftUI
import WidgetKit

/// The quick ways in on Apple Watch (WATCH-006): a complication for the watch face and the Smart
/// Stack that opens Mindloom and starts recording, and a control (Control Center, the Smart Stack,
/// the Action button on Apple Watch Ultra) that does the same.
@main
struct MindloomWatchWidgets: WidgetBundle {
  var body: some Widget {
    RecordComplication()
    RecordControl()
  }
}

struct RecordEntry: TimelineEntry {
  let date: Date
}

/// Nothing changes on the face: one entry, never refreshed.
struct RecordTimeline: TimelineProvider {
  func placeholder(in context: Context) -> RecordEntry { RecordEntry(date: Date()) }

  func getSnapshot(in context: Context, completion: @escaping (RecordEntry) -> Void) {
    completion(RecordEntry(date: Date()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<RecordEntry>) -> Void) {
    completion(Timeline(entries: [RecordEntry(date: Date())], policy: .never))
  }
}

struct RecordComplication: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "app.mindloom.watchkitapp.record", provider: RecordTimeline()) { _ in
      RecordComplicationView()
        .widgetURL(RecordRequest.url)
        .containerBackground(.fill.tertiary, for: .widget)
    }
    .configurationDisplayName("Mindloom 录音")
    .description("轻点后立即开始录音。")
    .supportedFamilies([
      .accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular,
    ])
  }
}

struct RecordComplicationView: View {
  @Environment(\.widgetFamily) private var family

  var body: some View {
    switch family {
    case .accessoryInline:
      Label("Mindloom 录音", systemImage: "mic.fill")
    case .accessoryCorner:
      Image(systemName: "mic.fill")
        .font(.title2)
        .widgetLabel("录音")
    case .accessoryRectangular:
      HStack(spacing: 8) {
        Image(systemName: "mic.circle.fill")
          .font(.title)
          .foregroundStyle(.red)
        VStack(alignment: .leading, spacing: 0) {
          Text("Mindloom")
            .font(.headline)
          Text("轻点录音")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
    default:
      ZStack {
        AccessoryWidgetBackground()
        Image(systemName: "mic.fill")
          .font(.title3)
      }
      .accessibilityLabel("Mindloom 录音")
    }
  }
}

struct RecordControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "app.mindloom.watchkitapp.record-control") {
      ControlWidgetButton(action: StartRecordingIntent()) {
        Label("Mindloom 录音", systemImage: "mic.fill")
      }
    }
    .displayName("Mindloom 录音")
    .description("在 Apple Watch 上开始录音。")
  }
}
