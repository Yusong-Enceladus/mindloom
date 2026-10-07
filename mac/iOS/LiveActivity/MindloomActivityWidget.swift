import ActivityKit
import AppIntents
import MindloomDesign
import SwiftUI
import WidgetKit

/// The voice session's Dynamic Island and Lock Screen banner (PHONE-SPEC §5.14). The pale mark
/// (#AFC2EC in both themes), 「语音已开启」, 「还剩 N 分钟」 or 「充电时保持开启」, and 「结束」. The
/// compact trailing side is left to the system's orange microphone indicator: never a time.
@main
struct MindloomActivityBundle: WidgetBundle {
  var body: some Widget {
    VoiceActivityWidget()
  }
}

struct VoiceActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: VoiceActivityAttributes.self) { context in
      LockScreenBanner(state: context.state, stale: context.isStale)
        .activityBackgroundTint(Color(red: 30 / 255, green: 30 / 255, blue: 34 / 255).opacity(0.52))
        .activitySystemActionForegroundColor(.white)
    } dynamicIsland: { context in
      DynamicIsland {
        // Mark and words together in the leading region (the centre region sits under the
        // camera and pushed the words 28 pt away from the mark and below its centre line);
        // 「结束」 trailing, all three on one centre line.
        DynamicIslandExpandedRegion(.leading) {
          HStack(spacing: 14) {
            IslandMark(height: 34, form: .medium)
            VStack(alignment: .leading, spacing: 0) {
              Text(context.isStale ? "语音已结束" : "语音已开启")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
              if !context.isStale {
                Text(context.state.detail)
                  .font(.system(size: 15))
                  .foregroundStyle(.white.opacity(0.62))
                  .monospacedDigit()
                  .lineLimit(1)
              }
            }
            .fixedSize()
          }
          .frame(maxHeight: .infinity, alignment: .center)
          .padding(.leading, 6)
          .dynamicIsland(verticalPlacement: .belowIfTooWide)
        }
        DynamicIslandExpandedRegion(.trailing) {
          EndButton(stale: context.isStale)
            .fixedSize()
            .frame(maxHeight: .infinity, alignment: .center)
            .padding(.trailing, 6)
            .dynamicIsland(verticalPlacement: .belowIfTooWide)
        }
      } compactLeading: {
        IslandMark(height: 16, form: .glyph)
      } compactTrailing: {
        // The system's orange microphone indicator sits here; nothing of ours.
        Color.clear.frame(width: 1, height: 1)
      } minimal: {
        IslandMark(height: 16, form: .glyph)
      }
      .keylineTint(IslandMark.pale)
    }
  }
}

/// The Lock Screen banner: mark M 30, two lines, 「结束」. Stale (the app stopped renewing it: it
/// died mid-session, or the countdown is over): 「语音已结束」 and 「关闭」, no countdown.
struct LockScreenBanner: View {
  let state: VoiceActivityAttributes.ContentState
  var stale = false

  var body: some View {
    HStack(spacing: 14) {
      IslandMark(height: 30, form: .medium)
      VStack(alignment: .leading, spacing: 0) {
        Text(stale ? "语音已结束" : "语音已开启")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(.white)
          .lineLimit(1)
        if !stale {
          Text(state.detail)
            .font(.system(size: 14))
            .foregroundStyle(.white.opacity(0.7))
            .monospacedDigit()
            .lineLimit(1)
        }
      }
      Spacer(minLength: 8)
      EndButton(stale: stale)
    }
    .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 16))
  }
}

/// 「结束」: a capsule, white @16 %, 15/500 white; ends the session in the app. 「关闭」 on a stale
/// activity: the same intent, which also removes an activity no session owns.
struct EndButton: View {
  var stale = false

  var body: some View {
    Button(intent: EndVoiceSessionIntent()) {
      Text(stale ? "关闭" : "结束")
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.white)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(Capsule().fill(.white.opacity(0.16)))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(stale ? "关闭" : "结束")
  }
}

/// The static mark in the island's pale indigo (both themes), sized by its ink height.
struct IslandMark: View {
  static let pale = Color(red: 0xAF / 255, green: 0xC2 / 255, blue: 0xEC / 255)
  let height: CGFloat
  let form: MindloomMarkForm

  var body: some View {
    MindloomMarkShape(form: form)
      .fill(Self.pale)
      .frame(width: height * MindloomMarkPainter.aspectRatio(form), height: height)
      .accessibilityLabel("Mindloom")
  }
}
