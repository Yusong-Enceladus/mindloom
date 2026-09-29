import AppKit
import BestASRCore
import BestASRDictation
import BestASRDomain
import BestASRInference
import BestASRMemoryUI
import BestASRPersistence
import Dispatch
import SwiftUI

// Home: moved out of ContentView.swift without change.
extension ContentView {
  /// One screen, no scrolling: how to dictate, how much has been dictated,
  /// and when. Setup cards appear above it only while setup is incomplete.
  var homeView: some View {
    VStack(alignment: .leading, spacing: 20) {
      PageHeader(title: "让声音被看见")
        .accessibilityIdentifier("bestASR.home.headline")

      if showsActiveCaptureWorkspace {
        unifiedActiveCaptureWorkspace
      }

      homeSetupCards
      homeAttentionCards
      dictationShortcutCard
      // Until history has been read these numbers are unknown rather than
      // zero, and a zero here reads as "you have never used this".
      dictationUsageTiles
        .redacted(reason: model.usage.usageLoaded ? [] : .placeholder)
      dictationActivityCard
        .redacted(reason: model.usage.usageLoaded ? [] : .placeholder)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 32)
    .padding(.vertical, 28)
    .frame(maxWidth: 900, alignment: .leading)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  /// First-run setup above Home, in the memory pages' own look: one quiet
  /// surface card per step, 15/13 pt type and capsule buttons (the accent
  /// only on the one step to take).
  @ViewBuilder
  var homeSetupCards: some View {
    if !model.startupFailureMessage.isEmpty {
      ZhijiSetupCard(
        step: nil, title: ZhijiCopy.setupStartupFailed, detail: model.startupFailureMessage
      ) { EmptyView() }
      .accessibilityIdentifier("bestASR.startupFailure")
    } else {
      if shouldShowPermissionSetup {
        ZhijiSetupCard(
          step: 1, stepTitle: "允许录音与回写", title: "让织机听见，并把结果送回原处",
          detail: "麦克风只用于你主动开始的录音；辅助功能让快捷键在任何 App 中生效，并在结束后把文字写回原来的输入位置。"
        ) {
          VStack(alignment: .leading, spacing: 10) {
            readinessCard(
              title: "麦克风",
              state: model.capture.microphonePermission,
              symbol: "mic",
              actionIdentifier: "bestASR.permission.microphone"
            ) {
              model.resolvePermission(.microphone)
            }
            readinessCard(
              title: "辅助功能",
              state: model.onboarding.accessibilityPermission,
              symbol: "cursorarrow.motionlines",
              actionIdentifier: "bestASR.permission.accessibility"
            ) {
              model.resolvePermission(.accessibility)
            }
          }
          if model.capture.microphonePermission == .granted {
            onboardingMicrophoneCheck
          }
          if model.capture.microphonePermission != .notDetermined
            || model.onboarding.accessibilityPermission != .notDetermined
          {
            DisclosureGroup("系统设置里出现多个织机？") {
              VStack(alignment: .leading, spacing: 5) {
                Text("只允许“应用程序”文件夹里的正式织机。")
                Text(model.permissionApplicationIdentity)
                  .font(.system(size: 11).monospaced())
                  .textSelection(.enabled)
              }
              .padding(.top, 5)
            }
            .font(.system(size: 11))
          }
          if !model.onboarding.permissionActionMessage.isEmpty {
            Text(model.onboarding.permissionActionMessage)
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("bestASR.permissionActionStatus")
          }
          HStack {
            if !isOnboardingIncomplete {
              Button("刷新状态") { model.refreshPermissions() }
            }
            Spacer()
            if isOnboardingIncomplete {
              Button("跳过首次设置") {
                deferFirstLaunchSetup()
              }
              .accessibilityIdentifier("bestASR.onboarding.deferPermissions")
            }
          }
        }
      } else if model.needsModelSetup,
        !modelSetupDeferred || !isOnboardingIncomplete
      {
        localSetupCard
      } else if !model.models.modelRuntimeReady,
        !modelSetupDeferred || !isOnboardingIncomplete
      {
        ZhijiSetupCard(
          step: isOnboardingIncomplete ? 2 : nil, stepTitle: "准备离线能力",
          title: "正在确认这台 Mac 是否已经可以离线识别…"
        ) {
          ProgressView().controlSize(.small)
        }
      } else if !practiceCompleted, !practiceDeferred,
        isOnboardingIncomplete
      {
        ZhijiSetupCard(
          step: 3, stepTitle: "完成一次真实口述", title: "先在这里试一句",
          detail: onboardingPracticeReady
            ? "让光标留在下面的框里，按 \(model.startEndShortcutTitle) 开始，说一句话，再按一次结束。"
              + "只有识别结果确实回到这里，练习才算完成。"
            : "你可以先进入织机。准备好缺少的项目后，这个真实口述练习仍会在首页等你。"
        ) {
          if onboardingPracticeReady {
            TextEditor(text: $practiceText)
              .font(.system(size: 13))
              .focused($practiceFieldFocused)
              .frame(minHeight: 76)
              .padding(6)
              .background(.background, in: RoundedRectangle(cornerRadius: 9))
              .overlay {
                RoundedRectangle(cornerRadius: 9)
                  .stroke(Color(nsColor: .separatorColor))
              }
              .accessibilityLabel("口述练习输入框")
              .accessibilityIdentifier("bestASR.onboarding.practiceEditor")
              .onChange(of: practiceFieldFocused) { _, focused in
                updateOnboardingPracticeTarget(focused: focused)
              }
              .onDisappear {
                model.setOnboardingPracticeTargetArmed(false)
              }
            HStack {
              if practiceSessionID != nil {
                ProgressView().controlSize(.small)
                Text("正在完成这次练习…")
                  .font(.system(size: 11))
                  .foregroundStyle(.secondary)
              } else {
                Button("把光标放回练习框") {
                  practiceDeferred = false
                  practiceFieldFocused = true
                }
                .accessibilityIdentifier("bestASR.onboarding.focusPractice")
              }
              Spacer()
              Button("稍后再试") {
                practiceDeferred = true
                practiceFieldFocused = false
              }
              .accessibilityIdentifier("bestASR.onboarding.deferPractice")
            }
          } else {
            HStack(spacing: 8) {
              if model.capture.microphonePermission != .granted {
                permissionAction(
                  title: "麦克风",
                  state: model.capture.microphonePermission,
                  identifier: "bestASR.onboarding.practiceMicrophone"
                ) { model.resolvePermission(.microphone) }
              }
              if model.onboarding.accessibilityPermission != .granted {
                permissionAction(
                  title: "辅助功能",
                  state: model.onboarding.accessibilityPermission,
                  identifier: "bestASR.onboarding.practiceAccessibility"
                ) { model.resolvePermission(.accessibility) }
              }
              if !model.models.modelRuntimeReady {
                Button("准备离线能力") {
                  modelSetupDeferred = false
                }
                .accessibilityIdentifier("bestASR.onboarding.resumeModels")
              }
              Spacer()
              Button("稍后再试") {
                practiceDeferred = true
                practiceFieldFocused = false
              }
              .accessibilityIdentifier("bestASR.onboarding.deferPractice")
            }
          }
          if !practiceStatusMessage.isEmpty {
            Text(practiceStatusMessage)
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("bestASR.onboarding.practiceStatus")
          }
        }
        .onAppear {
          if !practiceDeferred, onboardingPracticeReady {
            DispatchQueue.main.async { practiceFieldFocused = true }
          }
        }
      }
    }
  }

  @ViewBuilder
  /// Only the one thing Home may ask of the user: to finish setting up.
  /// Records that need attention are found in History, where they can be
  /// dealt with; Home is not a place for error reports.
  var homeAttentionCards: some View {
    if firstLaunchSetupWasDeferred {
      Button {
        resumeFirstLaunchSetup()
      } label: {
        HStack(spacing: 12) {
          Image(systemName: "checklist")
            .font(.system(size: 13))
            .foregroundStyle(.tint)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 2) {
            Text(ZhijiCopy.setupResume)
              .font(.system(size: 13, weight: .semibold))
            Text("检查权限、离线语音和快捷键；不影响你先浏览或记录。")
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
          }
          Spacer()
          Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
        }
        .padding(14)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .zhijiSurface()
      .accessibilityIdentifier("bestASR.onboarding.resume")
    }
  }

  /// How to dictate with the shortcuts actually configured.
  var dictationShortcutCard: some View {
    let startKey = model.hotkeys.startEndHotkeyBinding.isFunctionAlone ? "fn" : model.startEndShortcutTitle
    let rows: [(String, [String], String)] =
      model.hotkeys.startEndHotkeyBinding.isFunctionAlone
      ? [
        ("口述", [startKey], "按住说话，松开写入光标处；轻按则开始，再轻按结束"),
        ("翻译", [startKey, "⇧"], "说话时按一下 Shift，写入译文"),
        ("指令", [startKey, "空格"], "选中文字就改写它，没选中就写入答案"),
      ]
      : [
        ("口述", [startKey], "按一下开始，再按一下结束并写入")
      ]
    return VStack(alignment: .leading, spacing: 12) {
      Text("在任何 App 的输入框里使用")
        .font(.system(size: 14, weight: .semibold))
        .accessibilityIdentifier("bestASR.home.shortcuts")
      ForEach(rows, id: \.0) { row in
        HStack(spacing: 12) {
          Text(row.0)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 48, alignment: .leading)
          HStack(spacing: 4) {
            ForEach(row.1, id: \.self) { KeyCap(label: $0) }
          }
          .frame(width: 112, alignment: .leading)
          Text(row.2)
            .font(.system(size: 13))
          Spacer(minLength: 0)
        }
      }
    }
    .padding(18)
    .overlay {
      RoundedRectangle(cornerRadius: 12).strokeBorder(BestASRPalette.panelBorder)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("bestASR.home.shortcuts")
  }

  var dictationUsageTiles: some View {
    let usage = model.usage.usage
    let saved = usage.savedSeconds
    return HStack(spacing: 12) {
      UsageStatTile(
        title: "口述字数",
        value: usage.wordCount.formatted(),
        unit: "字",
        footnote: "共 \(usage.dictationCount) 次口述",
        identifier: "bestASR.home.words"
      )
      UsageStatTile(
        title: "节省时间",
        value: saved >= 3_600
          ? (saved / 3_600).formatted(.number.precision(.fractionLength(1)))
          : Int(saved / 60).formatted(),
        unit: saved >= 3_600 ? "小时" : "分钟",
        footnote: "对比每分钟打 \(Int(DictationUsageSummary.typingWordsPerMinute)) 字",
        identifier: "bestASR.home.saved"
      )
      UsageStatTile(
        title: "平均语速",
        value: usage.wordsPerMinute.map { $0.formatted() } ?? "—",
        unit: "字/分钟",
        footnote: "按实际说话时长计算",
        identifier: "bestASR.home.speed"
      )
      UsageStatTile(
        title: "连续天数",
        value: usage.currentStreakDays.formatted(),
        unit: "天",
        footnote: "最长 \(usage.longestStreakDays) 天",
        identifier: "bestASR.home.streak"
      )
    }
  }

  /// The last few things the user actually said. The home page is otherwise
  /// all numbers about dictation and no dictation, which makes it a page about
  /// the app rather than about their work.
  @ViewBuilder
  var dictationActivityCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text("活动")
          .font(.system(size: 14, weight: .semibold))
        Spacer()
        Text("累计活跃 \(model.usage.usage.activeDayCount) 天")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      }
      DictationActivityMap(wordsByDay: model.usage.usage.wordsByDay)
    }
    .padding(18)
    .overlay {
      RoundedRectangle(cornerRadius: 12).strokeBorder(BestASRPalette.panelBorder)
    }
  }

  func attentionCard(
    title: String,
    detail: String,
    symbol: String,
    tint: Color
  ) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: symbol)
        .font(.title2)
        .foregroundStyle(tint)
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.headline)
        Text(detail).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(18)
    .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
  }

  var isOnboardingIncomplete: Bool {
    !practiceCompleted
  }

  func updateOnboardingPracticeTarget(focused: Bool) {
    model.setOnboardingPracticeTargetArmed(
      focused && isOnboardingIncomplete
    )
  }

  var shouldShowPermissionSetup: Bool {
    if !isOnboardingIncomplete { return !onboardingPermissionsReady }
    return !permissionSetupDeferred
      && (!onboardingPermissionsReady || !onboardingMicrophoneChecked)
  }

  var firstLaunchSetupWasDeferred: Bool {
    isOnboardingIncomplete
      && (permissionSetupDeferred || modelSetupDeferred || practiceDeferred)
  }

  func deferFirstLaunchSetup() {
    permissionSetupDeferred = true
    modelSetupDeferred = true
    practiceDeferred = true
    practiceFieldFocused = false
    model.stopRoomLevelPreview()
  }

  func resumeFirstLaunchSetup() {
    permissionSetupDeferred = false
    modelSetupDeferred = false
    practiceDeferred = false
  }

  var onboardingMicrophoneCheck: some View {
    VStack(alignment: .leading, spacing: 10) {
      Divider()
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("确认麦克风")
            .font(.system(size: 13, weight: .semibold))
          Text("选好设备后说一句话；音量只在本机显示，不会保存。")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        Spacer()
        Picker("麦克风", selection: $model.capture.selectedRoomMicrophoneUID) {
          Text("系统默认麦克风").tag("")
          ForEach(model.capture.roomMicrophoneDevices) { device in
            Text(device.name).tag(device.uid)
          }
        }
        .labelsHidden()
        .frame(maxWidth: 260)
        .disabled(model.capture.roomLevelPreviewActive)
        .accessibilityIdentifier("bestASR.onboarding.microphonePicker")
      }
      HStack(spacing: 12) {
        ProgressView(value: model.capture.roomInputLevel)
          .frame(maxWidth: 360)
          .accessibilityLabel("麦克风输入音量")
          .accessibilityValue("\(Int(model.capture.roomInputLevel * 100))%")
          .accessibilityIdentifier("bestASR.onboarding.microphoneLevel")
        Text(
          onboardingMicrophoneChecked
            ? "麦克风正常"
            : model.capture.roomLevelPreviewActive ? "请说一句话" : "尚未检查"
        )
        .font(.system(size: 11))
        .foregroundStyle(onboardingMicrophoneChecked ? Color.primary : Color.secondary)
        .accessibilityIdentifier("bestASR.onboarding.microphoneCheckStatus")
        Spacer()
        Button(
          model.capture.roomLevelPreviewActive
            ? "停止检测" : onboardingMicrophoneChecked ? "再测一次" : "检查麦克风"
        ) {
          model.toggleRoomLevelPreview()
        }
        .accessibilityIdentifier("bestASR.onboarding.microphoneCheck")
      }
      if !onboardingMicrophoneChecked {
        Text(model.capture.roomStatusMessage)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("bestASR.onboarding.microphoneCheckDetail")
      }
    }
    .onAppear { model.refreshMicrophoneDevices() }
    .onDisappear { model.stopRoomLevelPreview() }
  }

  var onboardingPermissionsReady: Bool {
    model.capture.microphonePermission == .granted
      && model.onboarding.accessibilityPermission == .granted
  }

  var onboardingPracticeReady: Bool {
    onboardingPermissionsReady && model.models.modelRuntimeReady
  }

  func observePracticeDictation(_ phase: DictationPhase) {
    switch phase {
    case .preparing, .recording:
      guard practiceSessionID == nil, practiceFieldFocused,
        let sessionID = model.snapshot.sessionID
      else { return }
      practiceSessionID = sessionID
      practiceTextAtStart = practiceText
      practiceStatusMessage = "正在聆听；再按一次 \(model.startEndShortcutTitle) 结束"
    case .paused:
      guard model.snapshot.sessionID == practiceSessionID else { return }
      practiceStatusMessage = "练习已暂停；继续后仍会回到这个框"
    case .finalizing, .recognizing, .polishing, .inserting:
      guard model.snapshot.sessionID == practiceSessionID else { return }
      practiceStatusMessage = "录音已安全保存，正在本机识别并回写…"
    case .completed:
      guard let sessionID = practiceSessionID,
        model.snapshot.sessionID == sessionID
      else { return }
      let insertionReported = model.snapshot.insertion?.inserted == true
      practiceStatusMessage = "正在确认文字确实回到了练习框…"
      Task { @MainActor in
        if insertionReported {
          for _ in 0..<15 {
            guard practiceSessionID == sessionID else { return }
            if Self.practiceCompletionIsVisible(
              insertionReported: true,
              textBefore: practiceTextAtStart,
              textAfter: practiceText
            ) {
              practiceCompleted = true
              practiceDeferred = false
              practiceStatusMessage = "练习完成；以后在任何输入位置都可以这样口述"
              practiceSessionID = nil
              return
            }
            try? await Task.sleep(for: .milliseconds(100))
          }
        }
        guard practiceSessionID == sessionID else { return }
        practiceStatusMessage =
          "这次文字已保存在资料库，但没有真正回到练习框。把光标放回框里再试一次。"
        practiceFieldFocused = true
        practiceSessionID = nil
      }
    case .cancelled:
      guard model.snapshot.sessionID == practiceSessionID else { return }
      practiceSessionID = nil
      practiceStatusMessage = "这次练习已取消，没有留下不完整文字"
      DispatchQueue.main.async { practiceFieldFocused = true }
    case .failedRecoverable:
      guard model.snapshot.sessionID == practiceSessionID else { return }
      practiceSessionID = nil
      practiceStatusMessage = "这次没有完成；原音已安全保留，可以稍后从资料库恢复"
    case .idle:
      break
    case .cancelling:
      guard model.snapshot.sessionID == practiceSessionID else { return }
      practiceStatusMessage = "正在取消这次练习…"
    }
  }

  nonisolated static func practiceCompletionIsVisible(
    insertionReported: Bool,
    textBefore: String,
    textAfter: String
  ) -> Bool {
    insertionReported
      && textAfter != textBefore
      && !textAfter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func permissionAction(
    title: String,
    state: DictationPermissionState,
    identifier: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(
        Self.permissionActionTitle(title: title, state: state),
        systemImage: state == .granted
          ? "checkmark.circle.fill" : "arrow.up.forward.app"
      )
    }
    .disabled(
      state == .granted || state == .restricted
        || state == .restartRequired
    )
    .accessibilityIdentifier(identifier)
  }

  nonisolated static func permissionActionTitle(
    title: String,
    state: DictationPermissionState
  ) -> String {
    switch state {
    case .granted: "\(title)已允许"
    case .notDetermined: "允许\(title)"
    case .denied, .revoked: "打开\(title)设置"
    case .restricted: "\(title)受系统限制"
    case .restartRequired: "重新打开后生效"
    }
  }

  func captureModeCard(
    title: String,
    detail: String,
    footnote: String,
    symbol: String,
    tint: Color,
    identifier: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Image(systemName: symbol)
            .font(.title2)
            .foregroundStyle(tint)
            .frame(width: 38, height: 38)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
          Spacer()
          Image(systemName: "arrow.up.right")
            .foregroundStyle(.tertiary)
        }
        VStack(alignment: .leading, spacing: 4) {
          Text(title).font(.headline)
          Text(detail).foregroundStyle(.secondary)
          Text(footnote)
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
      .padding(18)
      .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(.quaternary.opacity(0.38), in: RoundedRectangle(cornerRadius: 16))
    .overlay {
      RoundedRectangle(cornerRadius: 16)
        .stroke(Color.primary.opacity(0.06))
    }
    .accessibilityIdentifier(identifier)
  }

  var localSetupCard: some View {
    ZhijiSetupCard(
      step: isOnboardingIncomplete ? 2 : nil, stepTitle: "准备离线能力", title: "准备离线语音",
      detail: "只需完成一次。之后转文字、分清谁在说话和整理文字都在这台 Mac 上完成。"
    ) {
      VStack(alignment: .leading, spacing: 14) {

        HStack(spacing: 10) {
          setupComponent(
            "语音转文字",
            detail: "中英混输与原音时间对齐 · 约 4.82 GB",
            symbol: "waveform"
          )
          setupComponent(
            "分清谁在说话",
            detail: "跨记录认出同一人物 · 约 22 MB",
            symbol: "person.2.wave.2"
          )
          setupComponent("整理文字", detail: "推荐 · 约 930 MB", symbol: "text.badge.checkmark")
        }

        Label(
          "人物声纹默认只在本机用于把不同记录中的同一人物归到一起，不用于登录、支付或解锁，也不会上传；可随时在设置中关闭并删除声纹特征，原音和文字不会随之删除。",
          systemImage: "person.crop.circle.badge.checkmark"
        )
        .font(.system(size: 11))
        .foregroundStyle(.secondary)

        if !model.onboarding.setupHardwareSupported {
          Label(
            model.onboarding.setupCompatibilityMessage,
            systemImage: "exclamationmark.triangle"
          )
          .accessibilityIdentifier("bestASR.setup.compatibility")
        }

        DisclosureGroup("查看第三方许可") {
          VStack(alignment: .leading, spacing: 8) {
            Link(
              "中文与混输识别许可",
              destination: URL(
                string:
                  "https://github.com/modelscope/FunASR/blob/d1007c323068d0c5aaa8e0f198668aaebc1a4fc2/MODEL_LICENSE"
              )!
            )
            Link(
              "英文识别许可与署名",
              destination: URL(
                string:
                  "https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml/tree/4252711f6f060f9a2f91e5f081a806d7f45eebd8"
              )!
            )
            Link(
              "多人识别许可与署名",
              destination: URL(
                string:
                  "https://huggingface.co/FluidInference/speaker-diarization-coreml/tree/1ed7a662fdc7109e36d822db793ee6eebdaf8594"
              )!
            )
            Link(
              "增强语音识别与时间对齐开源许可（Apache 2.0）",
              destination: URL(
                string:
                  "https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit/blob/a8379a2e2f9e313c9292cdf1af4055ab56d50d55/README.md"
              )!
            )
            Link(
              "文字整理组件许可",
              destination: URL(
                string:
                  "https://huggingface.co/Qwen/Qwen3-1.7B-MLX-4bit/blob/21457c6f51ed54a7c16e988c0844db973815c137/LICENSE"
              )!
            )
          }
          .padding(.top, 6)
        }

        Toggle(
          "我已阅读并接受上述三项离线能力的许可与署名要求",
          isOn: Binding(
            get: { model.recommendedComponentLicensesAccepted },
            set: { model.setRecommendedComponentLicensesAccepted($0) }
          )
        )
        .accessibilityIdentifier("bestASR.setup.licensesAccepted")

        HStack {
          Button("下载并开始使用") {
            modelSetupDeferred = false
            model.downloadRecommendedModels()
          }
          .buttonStyle(ZhijiCapsuleButtonStyle(prominent: true))
          .disabled(
            !model.recommendedComponentLicensesAccepted
              || !model.onboarding.setupHardwareSupported
              || model.models.recommendedModelInstallInProgress
          )
          .accessibilityIdentifier("bestASR.setup.download")
          if model.models.recommendedModelInstallInProgress {
            Button("暂停下载") { model.cancelRecommendedModelDownload() }
              .accessibilityIdentifier("bestASR.setup.cancelDownload")
          } else {
            Button("稍后设置") {
              modelSetupDeferred = true
              practiceDeferred = true
            }
            .accessibilityIdentifier("bestASR.onboarding.deferModels")
          }
        }
        if model.models.recommendedModelInstallInProgress {
          ProgressView(value: model.models.recommendedModelProgress)
            .accessibilityLabel("离线能力下载进度")
            .accessibilityValue("\(Int(model.models.recommendedModelProgress * 100))%")
        }
        Text(model.models.recommendedModelProgressMessage)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("bestASR.setup.status")
      }
    }
  }

  func setupComponent(
    _ title: String,
    detail: String,
    symbol: String
  ) -> some View {
    HStack(spacing: 10) {
      Image(systemName: symbol)
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .frame(width: 30, height: 30)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 13, weight: .semibold))
        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .padding(10)
    .frame(maxWidth: .infinity)
    .zhijiSurface(onSurface: true)
  }

  func readinessCard(
    title: String,
    state: DictationPermissionState,
    symbol: String,
    actionIdentifier: String,
    action: @escaping () -> Void
  ) -> some View {
    let actionable = state != .granted && state != .restricted && state != .restartRequired
    return ZhijiSetupRow(
      symbol: symbol, title: title, state: permissionTitle(state), done: state == .granted,
      actionTitle: actionable ? Self.permissionActionTitle(title: title, state: state) : nil,
      actionIdentifier: actionIdentifier, action: action)
  }

  func homeUsageCard(
    title: String,
    value: String,
    symbol: String
  ) -> some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        Label(title, systemImage: symbol)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(value)
          .font(.title2.bold())
          .lineLimit(1)
          .minimumScaleFactor(0.75)
      }
      .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
    }
  }

  func sourceModeButton(
    title: String,
    detail: String,
    symbol: String,
    identifier: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: symbol)
          .font(.title2)
          .frame(width: 30)
        VStack(alignment: .leading, spacing: 3) {
          Text(title).font(.headline)
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.right")
          .foregroundStyle(.tertiary)
      }
      .padding(12)
      .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityIdentifier(identifier)
  }

  func homeDurationTitle(_ nanoseconds: UInt64) -> String {
    let totalMinutes = nanoseconds / 60_000_000_000
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
    if minutes > 0 { return "\(minutes) 分钟" }
    return nanoseconds > 0 ? "少于 1 分钟" : "0 分钟"
  }

  func activeCaptureDurationTitle(
    _ snapshot: DictationSessionSnapshot
  ) -> String {
    let markers = snapshot.timeline.sorted {
      $0.monotonicNanoseconds < $1.monotonicNanoseconds
    }
    guard let started = markers.first(where: { $0.kind == .started }) else {
      return "0:00"
    }
    var elapsed: UInt64 = 0
    var activeStart: UInt64? = started.monotonicNanoseconds
    for marker in markers where marker.monotonicNanoseconds >= started.monotonicNanoseconds {
      switch marker.kind {
      case .started:
        if activeStart == nil { activeStart = marker.monotonicNanoseconds }
      case .resumed:
        activeStart = marker.monotonicNanoseconds
      case .paused, .endRequested, .cancelRequested:
        if let activeStart,
          marker.monotonicNanoseconds >= activeStart
        {
          elapsed += marker.monotonicNanoseconds - activeStart
        }
        activeStart = nil
      }
    }
    if [.preparing, .recording].contains(snapshot.phase),
      let activeStart
    {
      let now = DispatchTime.now().uptimeNanoseconds
      if now >= activeStart { elapsed += now - activeStart }
    }
    return formatPlaybackTime(Double(elapsed) / 1_000_000_000)
  }

  var modelReadinessCard: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        Label("识别", systemImage: "cpu")
          .font(.headline)
        Text(model.modelReadinessHeadline)
          .foregroundStyle(model.models.modelRuntimeReady ? Color.green : Color.orange)
          .accessibilityIdentifier("bestASR.modelReadiness")
        if model.modelReadinessHeadline == "需要准备" {
          SettingsLink { Text("完成设置") }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("bestASR.modelSetup")
        }
      }
      .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
    }
  }

  func compactPreview(
    _ text: String?,
    limit: Int = 96
  ) -> String? {
    guard let text else { return nil }
    let normalized =
      text
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
    guard !normalized.isEmpty else { return nil }
    let boundedLimit = max(1, limit)
    guard normalized.count > boundedLimit else { return normalized }
    return String(normalized.prefix(boundedLimit)) + "…"
  }

  func permissionTitle(_ state: DictationPermissionState) -> String {
    switch state {
    case .granted: "已允许"
    case .notDetermined: "尚未允许"
    case .denied: "已拒绝"
    case .restricted: "受系统限制"
    case .revoked: "权限已被关闭"
    case .restartRequired: "已允许，重新打开 App 后生效"
    }
  }

  static func personDuration(_ nanoseconds: UInt64) -> String {
    let total = Int(nanoseconds / 1_000_000_000)
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    let seconds = total % 60
    if hours > 0 { return "\(hours)小时\(minutes)分" }
    if minutes > 0 { return "\(minutes)分\(seconds)秒" }
    return "\(seconds)秒"
  }
}
