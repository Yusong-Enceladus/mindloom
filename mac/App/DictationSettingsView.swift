import BestASRDictation
import BestASRDomain
import BestASRMacUI
import BestASRRemoteOrganizer
import SwiftUI

private enum DictationSettingsCategory: String, CaseIterable, Identifiable, Hashable {
  case general
  case shortcuts
  case recording
  case models
  case language
  case data
  case agents

  var id: String { rawValue }

  /// What Settings shows. The rest — component provisioning, offline
  /// deployment, verification and rollback, per-App text policies — is
  /// operator tooling, kept whole but reached from 更多 → 高级 instead of
  /// sitting beside the microphone picker.
  static let primary: [Self] = [.general, .shortcuts, .recording, .data, .agents]
  static let advanced: [Self] = [.models, .language]

  var title: String {
    switch self {
    case .general: "通用"
    case .shortcuts: "快捷键"
    case .recording: "麦克风"
    case .models: "识别组件"
    case .language: "文字格式"
    case .data: "数据"
    case .agents: "Agent"
    }
  }

  var symbol: String {
    switch self {
    case .general: "switch.2"
    case .shortcuts: "keyboard"
    case .recording: "waveform"
    case .models: "shippingbox"
    case .language: "character.book.closed"
    case .data: "lock.shield"
    case .agents: "person.badge.key"
    }
  }
}

/// Which categories a settings window shows.
enum DictationSettingsScope {
  /// Settings: what a user of a dictation app expects to find there.
  case primary
  /// The 高级 window: the operator categories, reached from 更多.
  case advanced
  /// Every category in one window, for the UI tests that walk them all.
  case all
}

struct DictationSettingsView: View {
  @ObservedObject var model: DictationAppModel
  let scope: DictationSettingsScope
  @State private var selectedCategory = DictationSettingsCategory.general
  @State private var confirmSpeakerMemoryDeletion = false
  @State private var confirmSparkForget = false
  @State private var confirmPhoneDisconnect = false
  @State private var confirmRebuildableCacheDeletion = false
  @State private var pendingHistoryClearMode: SessionInputMode?
  @State private var pendingAppPolicyDeletion: AppTextPolicy?

  private var categories: [DictationSettingsCategory] {
    switch scope {
    case .primary: DictationSettingsCategory.primary
    case .advanced: DictationSettingsCategory.advanced
    case .all: DictationSettingsCategory.allCases
    }
  }

  init(model: DictationAppModel, scope: DictationSettingsScope = .primary) {
    self.model = model
    self.scope = scope
    _selectedCategory = State(initialValue: scope == .advanced ? .models : .general)
  }

  /// "连接 iPhone" / "断开 iPhone" (PHONE-CONTRACT §4). Connecting is offered
  /// only while the link above is on; disconnecting whenever a phone is
  /// paired, so a lost phone can always be cut off.
  @ViewBuilder private var phoneLinkSection: some View {
    let phone = model.phoneLink
    if let paired = phone.paired {
      Text("已连接 iPhone · \(paired.pairedAt.formatted(date: .abbreviated, time: .shortened))")
        .accessibilityIdentifier("bestASR.settings.phonePaired")
    } else {
      Text("没有连接 iPhone")
    }
    Text(
      "iPhone 上用织机键盘说的话、用「收进织机」分享的文字、链接、图片和文件，会在手机上锁好，只有这台 Mac 打得开；经你的整理设备转交，这台 Mac 取走后整理设备就删掉。手机的钥匙只能往收件箱里放东西。"
    )
    .font(.caption)
    .foregroundStyle(.secondary)
    HStack {
      Button(phone.paired == nil ? "连接 iPhone" : "重新连接 iPhone") {
        model.connectIPhone()
      }
      .disabled(!model.canConnectIPhone)
      .accessibilityIdentifier("bestASR.settings.phoneConnect")
      if phone.paired != nil {
        Button("断开 iPhone", role: .destructive) {
          confirmPhoneDisconnect = true
        }
        .disabled(phone.working || phone.service == nil)
        .accessibilityIdentifier("bestASR.settings.phoneDisconnect")
      }
      if phone.working {
        ProgressView().controlSize(.small)
      }
    }
    .sheet(
      isPresented: Binding(
        get: { model.phoneLink.pairingCode != nil },
        set: { if !$0 { model.finishPhonePairingCode() } }
      )
    ) {
      if let code = model.phoneLink.pairingCode {
        PhonePairingCodeSheet(
          code: code, copy: { model.copyPhonePairingCode() },
          done: { model.finishPhonePairingCode() })
      }
    }
    .confirmationDialog(
      "断开 iPhone？", isPresented: $confirmPhoneDisconnect, titleVisibility: .visible
    ) {
      Button("断开", role: .destructive) { model.disconnectIPhone() }
      Button("取消", role: .cancel) {}
    } message: {
      Text("这台 iPhone 的钥匙会从整理设备和中转主机上删除，之后它送出的内容不再被接收。已经收进这台 Mac 的内容不受影响。")
    }
    if !model.remoteOrganizerEnabled, phone.paired == nil {
      Text("先打开上面的整理设备链路，再连接 iPhone。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    if let status = phone.statusMessage {
      Text(status)
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("bestASR.settings.phoneStatus")
    }
    if !phone.droppedNotices.isEmpty {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(phone.droppedNotices, id: \.self) { notice in
            Text(notice)
          }
        }
        .font(.caption)
        .foregroundStyle(.orange)
        Spacer()
        Button("知道了") { model.dismissPhoneDropNotices() }
          .controlSize(.small)
      }
      .accessibilityIdentifier("bestASR.settings.phoneDropped")
    }
  }

  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 12) {
        Text(scope == .advanced ? "高级" : "设置")
          .font(.largeTitle.bold())
          .padding(.horizontal, 16)
          .padding(.top, 18)
        ScrollView {
          VStack(spacing: 5) {
            ForEach(categories) { category in
              Button {
                selectedCategory = category
              } label: {
                Label(category.title, systemImage: category.symbol)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(.horizontal, 11)
                  .padding(.vertical, 9)
                  .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .background(
                selectedCategory == category
                  ? Color.accentColor.opacity(0.16) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
              )
              .accessibilityLabel(category.title)
              .accessibilityIdentifier(
                "bestASR.settings.category.\(category.rawValue)"
              )
            }
          }
          .padding(.horizontal, 9)
        }
        .accessibilityIdentifier("bestASR.settings.category")
        Spacer(minLength: 0)
        Spacer().frame(height: 16)
      }
      .frame(width: 190)
      .background(BestASRPalette.canvas)

      Divider()

      Form {
        Section {
          Label(selectedCategory.title, systemImage: selectedCategory.symbol)
            .font(.title2.bold())
        }
        if [.general, .shortcuts, .recording].contains(selectedCategory) {
          if selectedCategory == .shortcuts {
            Section("全局快捷键") {
              Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                  Text("开始 / 结束")
                  HotkeyRecorderField(
                    binding: $model.hotkeys.startEndHotkeyBinding,
                    accessibilityIdentifier: "bestASR.settings.startEndHotkey",
                    accessibilityLabel: "开始或结束口述快捷键"
                  )
                  .frame(width: 220, height: 32)
                  Menu("常用") {
                    ForEach(DictationHotkeyPreset.alphaPresets) { preset in
                      Button(preset.title) {
                        model.useHotkeyPreset(preset.id, for: .startOrEnd)
                      }
                    }
                  }
                }
              }
              if model.hotkeys.startEndHotkeyBinding.isFunctionAlone {
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                  GridRow {
                    Text("翻译")
                    Text("Fn ⇧")
                      .font(.system(size: 12, weight: .medium, design: .monospaced))
                    Text("按住 Fn 说话时按一下 Shift，写入的是译文")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                  GridRow {
                    Text("指令")
                    Text("Fn 空格")
                      .font(.system(size: 12, weight: .medium, design: .monospaced))
                    Text("说出要做的事；选中了文字就改写它，没选中就给出答案")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                }
                .accessibilityIdentifier("bestASR.settings.spokenModes")
                VStack(alignment: .leading, spacing: 6) {
                  Text("翻译成")
                  FlowLayout(spacing: 6) {
                    ForEach(DictationAppModel.translationLanguageNames, id: \.self) { name in
                      let chosen = model.spoken.translationTargetLanguageNames.contains(name)
                      Button {
                        model.toggleTranslationLanguage(name)
                      } label: {
                        Text(name)
                          .font(.system(size: 12.5))
                          .padding(.horizontal, 11)
                          .padding(.vertical, 5)
                          .background(
                            chosen ? BestASRPalette.accent.opacity(0.16) : BestASRPalette.quietFill,
                            in: Capsule()
                          )
                          .overlay {
                            Capsule().strokeBorder(
                              chosen
                                ? BestASRPalette.accent.opacity(0.7) : BestASRPalette.panelBorder)
                          }
                      }
                      .buttonStyle(.plain)
                      .accessibilityIdentifier("bestASR.settings.translationLanguage.\(name)")
                    }
                  }
                  Text(
                    model.spoken.translationTargetLanguageNames.count > 1
                      ? "说话时每多按一下 Shift，就换到下一个语言。"
                      : "最多选 3 个；选了多个时，说话时每多按一下 Shift 就换一个。"
                  )
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  // What the system engine can do for the pairs chosen above.
                  // Language packs are the system's, downloaded once through
                  // its own prompt, so they cost this app no disk and no
                  // resident memory — and nothing is fetched unless asked.
                  ForEach(model.spoken.translationTargetLanguageNames, id: \.self) { target in
                    let source = DictationAppModel.translationSource(for: target)
                    HStack(spacing: 8) {
                      Text("\(source) → \(target)")
                        .font(.caption)
                      switch model.spoken.translationEngineStatus[target] {
                      case .installed:
                        Label("系统翻译已就绪", systemImage: "checkmark.circle.fill")
                          .font(.caption)
                          .foregroundStyle(.green)
                      case .downloadable:
                        if model.models.translationInstallInProgress == target {
                          ProgressView().controlSize(.small)
                        } else {
                          Button("下载语言") { model.installTranslationLanguage(target) }
                            .controlSize(.small)
                            .accessibilityIdentifier(
                              "bestASR.settings.installTranslation.\(target)")
                        }
                        Text("下载前按原文写入")
                          .font(.caption)
                          .foregroundStyle(.secondary)
                      case .unsupported, .unavailable, .none:
                        Text("系统不支持这一对")
                          .font(.caption)
                          .foregroundStyle(.secondary)
                      }
                      Spacer(minLength: 0)
                    }
                  }
                  .accessibilityIdentifier("bestASR.settings.translationEngine")
                }
                .onAppear { model.refreshTranslationEngineStatus() }
                .onChange(of: model.spoken.translationTargetLanguageNames) { _, _ in
                  model.refreshTranslationEngineStatus()
                }
                .accessibilityIdentifier("bestASR.settings.translationLanguage")
                Text("翻译用系统自带的翻译引擎。")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              } else {
                Text("把口述快捷键设为 Fn 单键后，可以用 Fn ⇧ 翻译、Fn 空格 下指令。")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .accessibilityIdentifier("bestASR.settings.spokenModesUnavailable")
              }
              Button("应用快捷键") { model.applyHotkeyConfiguration() }
                .disabled(!model.hotkeySelectionIsSafe)
                .accessibilityIdentifier("bestASR.settings.applyHotkeys")
              Text(model.hotkeys.hotkeyStatusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("bestASR.settings.hotkeyStatus")
              Text("点选输入框后直接按新组合；支持 Fn 单键、Fn + 按键及常规修饰键组合。快捷键与其他应用冲突时会保留原设置。")
                .font(.caption)
                .foregroundStyle(.secondary)
              if model.hotkeys.globeKeyConflictsWithStartShortcut {
                VStack(alignment: .leading, spacing: 6) {
                  Label(
                    "按 Fn 时，macOS 也会执行 🌐 键操作（切换输入法或弹出表情）",
                    systemImage: "exclamationmark.triangle"
                  )
                  Text("请在 系统设置 → 键盘 中，把“按下 🌐 键时”设为“不执行任何操作”。织机不会替你修改系统设置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                  Button("打开键盘设置") { model.openKeyboardSettings() }
                    .accessibilityIdentifier("bestASR.settings.openKeyboardSettings")
                }
                .accessibilityIdentifier("bestASR.settings.globeKeyConflict")
              }
            }
            .onAppear { model.refreshGlobeKeyConflict() }
          }
          if selectedCategory == .general {
            Section("应用与口述行为") {
              Toggle(
                "登录后自动启动",
                isOn: Binding(
                  get: { model.launchAtLoginEnabled },
                  set: { model.setLaunchAtLoginEnabled($0) }
                )
              )
              Toggle("显示菜单栏图标", isOn: $model.menuBarEnabled)
              // 界面语言 was a row that looked like a control and was not
              // one, and the generic polish switch was one whose own
              // description said turning it on made the text worse. A switch
              // that offers to degrade the result is not a preference. The
              // per-app control under 文字格式 remains, where turning it on
              // for one editor is a judgement the user can actually make.
              if model.models.personalCleanupInstalled {
                Toggle(
                  "整理口述文字",
                  isOn: Binding(
                    get: { model.people.personalCleanupEnabled },
                    set: { model.setPersonalCleanupEnabled($0) }
                  )
                )
                Text("去掉语气词、重复和改口；改动过多时退回规则整理。")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              // Push-to-talk was a switch explaining that, with it off, the
              // key already behaved that way. Holding to talk and tapping to
              // toggle is now how every shortcut behaves, so there is nothing
              // left to choose.
              Toggle(
                "只在鼠标悬停时显示实时字幕",
                isOn: Binding(
                  get: { model.capsuleSubtitlesRequireHover },
                  set: { model.setCapsuleSubtitlesRequireHover($0) }
                )
              )
              .accessibilityIdentifier("bestASR.settings.subtitlesHoverOnly")
              Text(model.preferencesStatusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section("App 更新") {
              Toggle(
                "自动检查更新",
                isOn: Binding(
                  get: { model.models.automaticAppUpdateChecks },
                  set: { model.setAutomaticAppUpdateChecks($0) }
                )
              )
              HStack {
                Button("检查更新") { model.checkForAppUpdate() }
                  .disabled(model.models.appUpdateCheckInProgress)
                if model.models.appUpdateCheckInProgress {
                  ProgressView().controlSize(.small)
                }
                if model.models.availableAppUpdateURL != nil {
                  Button("打开官方发布页") { model.openAvailableAppUpdate() }
                }
              }
              Text(model.models.appUpdateStatusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          if selectedCategory == .recording {
            Section("录音默认项") {
              Picker("线下录音麦克风", selection: $model.capture.selectedRoomMicrophoneUID) {
                Text("跟随系统默认").tag("")
                ForEach(model.capture.roomMicrophoneDevices) { device in
                  Text(device.name).tag(device.uid)
                }
              }
              Toggle(
                "电脑内录时同时录制麦克风独立音轨",
                isOn: Binding(
                  get: { model.history.includeMicrophoneInSystemRecording },
                  set: { model.setIncludeMicrophoneInSystemRecording($0) }
                )
              )
              if model.history.includeMicrophoneInSystemRecording {
                Picker(
                  "电脑内录麦克风",
                  selection: $model.capture.selectedSystemMicrophoneUID
                ) {
                  Text("跟随系统默认").tag("")
                  ForEach(model.capture.roomMicrophoneDevices) { device in
                    Text(device.name).tag(device.uid)
                  }
                }
              }
              LabeledContent("采集格式", value: "48 kHz · 32 位浮点 · 无损分块")
            }
          }
          if selectedCategory == .shortcuts {
            Section("权限") {
              Text("Fn 单键和写入其他 App 需要辅助功能权限。")
                .font(.caption)
                .foregroundStyle(.secondary)
              permissionRow("麦克风", state: model.capture.microphonePermission) {
                model.resolvePermission(.microphone)
              }
              permissionRow("辅助功能", state: model.onboarding.accessibilityPermission) {
                model.resolvePermission(.accessibility)
              }
              permissionRow(
                "屏幕与系统音频录制",
                state: model.capture.systemAudioPermission
              ) {
                model.resolvePermission(.systemAudioCapture)
              }
              Button("刷新状态") { model.refreshPermissions() }
              DisclosureGroup("系统设置里有多个织机？") {
                VStack(alignment: .leading, spacing: 6) {
                  Text("只保留并允许“应用程序”文件夹里的正式织机。当前运行身份如下：")
                  Text(model.permissionApplicationIdentity)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                }
                .padding(.top, 6)
              }
              .font(.caption)
            }
          }
        }
        if selectedCategory == .models {
          Section("识别组件") {
            Text("推荐配置")
              .font(.headline)
            Text(
              "中英混输识别与时间对齐组件约 4.82 GB，多人人物识别组件约 22 MB，文字整理组件约 930 MB。只补充缺失组件；安装后可离线使用，录音、文字、词典、人物信息和当前应用信息不会离开这台 Mac。"
            )
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
              Link(
                "查看中文与混输识别许可",
                destination: URL(
                  string:
                    "https://github.com/modelscope/FunASR/blob/d1007c323068d0c5aaa8e0f198668aaebc1a4fc2/MODEL_LICENSE"
                )!
              )
              .accessibilityIdentifier("bestASR.settings.funASRLicense")
              Link(
                "查看英文识别许可与署名",
                destination: URL(
                  string:
                    "https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml/tree/4252711f6f060f9a2f91e5f081a806d7f45eebd8"
                )!
              )
              .accessibilityIdentifier("bestASR.settings.parakeetLicense")
              Link(
                "查看增强语音识别与时间对齐开源许可（Apache 2.0）",
                destination: URL(
                  string:
                    "https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit/blob/a8379a2e2f9e313c9292cdf1af4055ab56d50d55/README.md"
                )!
              )
              .accessibilityIdentifier("bestASR.settings.qwenASRLicense")
              Link(
                "查看多人识别许可与署名",
                destination: URL(
                  string:
                    "https://huggingface.co/FluidInference/speaker-diarization-coreml/tree/1ed7a662fdc7109e36d822db793ee6eebdaf8594"
                )!
              )
              .accessibilityIdentifier("bestASR.settings.speakerLicense")
              Link(
                "查看文字整理组件许可",
                destination: URL(
                  string:
                    "https://huggingface.co/Qwen/Qwen3-1.7B-MLX-4bit/blob/21457c6f51ed54a7c16e988c0844db973815c137/LICENSE"
                )!
              )
              .accessibilityIdentifier("bestASR.settings.qwenLicense")
            }
            Toggle(
              "我接受基础语音识别组件许可与署名要求",
              isOn: Binding(
                get: { model.models.modelLicenseAccepted },
                set: { model.setSpeechModelLicenseAccepted($0) }
              )
            )
            .accessibilityIdentifier("bestASR.settings.modelLicenseAccepted")
            Toggle(
              "我接受上方多人识别组件许可与署名要求",
              isOn: Binding(
                get: { model.models.speakerModelLicenseAccepted },
                set: { model.setSpeakerModelLicenseAccepted($0) }
              )
            )
            .accessibilityIdentifier("bestASR.settings.speakerModelLicenseAccepted")
            Toggle(
              "我接受上方文字整理组件许可",
              isOn: Binding(
                get: { model.models.polishModelLicenseAccepted },
                set: { model.setPolishModelLicenseAccepted($0) }
              )
            )
            .accessibilityIdentifier("bestASR.settings.polishModelLicenseAccepted")
            Button("下载并准备推荐组件") {
              model.downloadRecommendedModels()
            }
            .buttonStyle(.borderedProminent)
            .disabled(
              !model.canInstallRecommendedModels
                || model.models.recommendedModelInstallInProgress
            )
            .accessibilityIdentifier("bestASR.settings.downloadRecommendedModels")
            if model.models.recommendedModelInstallInProgress {
              ProgressView(value: model.models.recommendedModelProgress)
                .accessibilityLabel("推荐组件下载进度")
                .accessibilityValue(
                  "百分之 \(Int(model.models.recommendedModelProgress * 100))"
                )
              Button("取消下载") {
                model.cancelRecommendedModelDownload()
              }
              .accessibilityIdentifier("bestASR.settings.cancelModelDownload")
            }
            Text(model.models.recommendedModelProgressMessage)
              .font(.caption)
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("bestASR.settings.modelDownloadStatus")
            Text(model.models.modelReadinessMessage)
              .font(.callout)
              .accessibilityIdentifier("bestASR.settings.modelReadiness")
            Text(model.people.speakerReadinessMessage)
              .font(.callout)
              .accessibilityIdentifier("bestASR.settings.speakerReadiness")

            ForEach(model.localModelComponents) { item in
              HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                  Text(item.component.title)
                    .font(.callout.weight(.medium))
                  Text(DictationAppModel.byteCountTitle(item.sizeBytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Label(
                  item.ready ? "已校验" : "未就绪",
                  systemImage: item.ready ? "checkmark.seal.fill" : "exclamationmark.triangle"
                )
                .foregroundStyle(item.ready ? Color.green : Color.orange)
              }
            }

            Toggle(
              "允许联网下载识别组件",
              isOn: Binding(
                get: { model.models.allowModelDownloads },
                set: { model.setAllowModelDownloads($0) }
              )
            )
            Toggle(
              "自动检查并安装已验证的组件更新",
              isOn: Binding(
                get: { model.models.automaticModelUpdates },
                set: { model.setAutomaticModelUpdates($0) }
              )
            )
            .disabled(!model.models.allowModelDownloads)
            HStack {
              Button("校验已安装组件") { model.verifyInstalledModels() }
              Menu("恢复上一可用版本") {
                ForEach(LocalModelComponent.allCases) { component in
                  Button(component.title) {
                    model.restoreLastKnownGoodModel(component)
                  }
                }
              }
            }
            Text(model.models.modelManagementStatusMessage)
              .font(.caption)
              .foregroundStyle(.secondary)

            DisclosureGroup("高级诊断与离线部署") {
              VStack(alignment: .leading, spacing: 10) {
                Text("语音识别")
                  .font(.headline)
                Text(model.models.modelReadinessMessage)
                HStack {
                  Button("选择混输识别文件夹…") {
                    model.chooseAndInstallLocalModel()
                  }
                  .disabled(
                    !model.models.modelLicenseAccepted || model.models.modelInstallInProgress
                  )
                  .accessibilityIdentifier("bestASR.settings.installModel")
                  if model.models.modelInstallInProgress {
                    ProgressView().controlSize(.small)
                  }
                }
                Text(
                  "仅用于高级离线部署：这里安装混输与实时识别基线。完整推荐安装还会自动准备中文和英文终稿组件，普通用户无需选择。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Divider()
                Text("安全文字整理")
                  .font(.headline)
                Text(model.polishReadinessMessage)
                  .accessibilityIdentifier("bestASR.settings.polishReadiness")
                HStack {
                  Button("选择 Qwen 文件夹…") {
                    model.chooseAndInstallPolishModel()
                  }
                  .disabled(
                    !model.models.polishModelLicenseAccepted
                      || model.models.polishModelInstallInProgress
                  )
                  .accessibilityIdentifier("bestASR.settings.installPolishModel")
                  if model.models.polishModelInstallInProgress {
                    ProgressView().controlSize(.small)
                  }
                }
                Text(
                  "应用会在本机校验精确匹配的 930.3 MB Qwen3 文件。组件不可用时仍会保留原始识别文字，并使用安全标点整理。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Divider()
                Text("多人识别")
                  .font(.headline)
                Text(model.people.speakerReadinessMessage)
                HStack {
                  Button("选择多人识别组件文件夹…") {
                    model.chooseAndInstallSpeakerModel()
                  }
                  .disabled(
                    !model.models.speakerModelLicenseAccepted
                      || model.models.speakerModelInstallInProgress
                  )
                  .accessibilityIdentifier("bestASR.settings.installSpeakerModel")
                  if model.models.speakerModelInstallInProgress {
                    ProgressView().controlSize(.small)
                  }
                }
                Text(
                  "应用会在本机逐项校验固定版本的约 21.6 MB Core ML 文件；运行时不会自动联网补文件。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
              }
              .padding(.top, 6)
            }
          }
        }
        if selectedCategory == .language {
          Section("App 专属文字策略") {
            Text(
              "默认策略适用于所有 App；你可以为常用 App 单独关闭文字整理，或选择纯文本、Markdown、代码注释等格式。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            ForEach(model.appTextPolicies) { policy in
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(policy.displayName)
                }
                .help(policy.bundleIdentifier)
                Spacer()
                Text(policy.polishEnabled ? "整理文字" : "仅安全标点")
                  .foregroundStyle(.secondary)
                Text(policy.formattingStyle.title)
                  .foregroundStyle(.secondary)
                Button("删除…", role: .destructive) {
                  pendingAppPolicyDeletion = policy
                }
              }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
              GridRow {
                Text("选择 App")
                HStack {
                  Picker(
                    "",
                    selection: Binding(
                      get: { model.appPolicyBundleIDDraft },
                      set: { model.selectAppTextPolicyChoice($0) }
                    )
                  ) {
                    Text("选择正在运行的 App…").tag("")
                    ForEach(model.appTextPolicyChoices) { choice in
                      Text(choice.displayName).tag(choice.bundleIdentifier)
                    }
                  }
                  .labelsHidden()
                  .accessibilityIdentifier("bestASR.settings.appPolicyApplication")
                  Button("刷新") { model.refreshSystemAudioSources() }
                }
              }
              GridRow {
                Text("文字格式")
                Picker("", selection: $model.appPolicyFormattingStyle) {
                  ForEach(AppTextFormattingStyle.allCases) { style in
                    Text(style.title).tag(style)
                  }
                }
                .labelsHidden()
                .accessibilityIdentifier("bestASR.settings.appPolicyFormat")
              }
            }
            Toggle("为这个 App 整理口述文字", isOn: $model.appPolicyPolishEnabled)
            Button("保存 App 策略") { model.saveAppTextPolicy() }
              .disabled(
                model.appPolicyBundleIDDraft
                  .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              )
              .accessibilityIdentifier("bestASR.settings.appPolicySave")
            DisclosureGroup("高级：手动指定 App") {
              Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                  Text("显示名称")
                  TextField("例如 TextEdit", text: $model.appPolicyDisplayNameDraft)
                }
                GridRow {
                  Text("Bundle ID")
                  TextField(
                    "例如 com.apple.TextEdit",
                    text: $model.appPolicyBundleIDDraft
                  )
                }
              }
              .padding(.top, 6)
            }
          }
        }
        if selectedCategory == .data {
          Section("我的整理设备") {
            Toggle(
              "通过 SSH 发送整理所需的文字到我的整理设备",
              isOn: Binding(
                get: { model.remoteOrganizerEnabled },
                set: { model.setRemoteOrganizerEnabled($0) }
              )
            )
            .accessibilityIdentifier("bestASR.settings.sparkOrganizer")
            Text(model.events.remoteStatusMessage)
              .font(.caption)
              .foregroundStyle(.secondary)
            if let clock = model.events.remoteServiceClock, clock != "wall" {
              // An eval or test configuration of the organizer, not production.
              Text("整理设备在测试配置下运行")
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("bestASR.settings.organizerTestClock")
            }
            Text(
              "开启后只发送开启后开始的记录的文字、分段、人物名称和来源 App，以及你在事件页做的整理决定；发送前，手机号、邮箱、证件号、银行卡号、验证码、密码和密钥会先换成占位符，截图里的这些号码会被涂掉，结果回到 Mac 时再换回原文。录音、声纹、词典、原始文件和音视频始终留在 Mac。整理设备上的内容用只存在这台 Mac 钥匙串里的钥匙锁住，图片和文件读完即删；你在 Mac 上删除的记录，整理设备上也会删除。关闭会先让整理设备锁上，再停止一切发送、断开 SSH 隧道并清空待发队列；关闭期间的记录和修改不会在重新开启后自动补发。从归档导入会关闭链路，导入的内容不会自动发送。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Button(
              model.remoteOrganizerHoldsOtherKey ? "让整理设备忘掉旧内容" : "让整理设备忘掉我的内容",
              role: .destructive
            ) {
              confirmSparkForget = true
            }
            .disabled(!model.remoteOrganizerCanForget || model.remoteOrganizerForgetting)
            .accessibilityIdentifier("bestASR.settings.sparkForget")
            .confirmationDialog(
              model.remoteOrganizerHoldsOtherKey ? "让整理设备忘掉旧内容？" : "让整理设备忘掉你的内容？",
              isPresented: $confirmSparkForget,
              titleVisibility: .visible
            ) {
              Button(
                model.remoteOrganizerHoldsOtherKey ? "忘掉旧内容" : "忘掉并销毁钥匙", role: .destructive
              ) {
                model.forgetRemoteOrganizerContent()
              }
              Button("取消", role: .cancel) {}
            } message: {
              Text(
                model.remoteOrganizerHoldsOtherKey
                  ? "整理设备会删除用另一把钥匙保存的全部内容；这台 Mac 上的记录不受影响。"
                  : "整理设备会删除它为你保存的全部内容，这台 Mac 上的钥匙也会销毁；Mac 上的记录和整理结果都保留，之后只发送新的或改过的记录。"
              )
            }
          }
          Section("iPhone") {
            phoneLinkSection
          }
          Section("人物与声纹隐私") {
            Toggle(
              "在本机记住人物声纹，用于之后的自动匹配",
              isOn: Binding(
                get: { model.people.speakerMemoryEnabled },
                set: { enabled in
                  if enabled {
                    model.setSpeakerMemoryEnabled(true)
                  } else {
                    confirmSpeakerMemoryDeletion = true
                  }
                }
              )
            )
            Text(
              "关闭会删除全部声纹向量并停止新的自动匹配；不会删除原音、逐字稿、人物名称或你人工确认的关系。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Button("重建未确认的声纹索引") {
              model.reevaluateAutomaticPersonMatches()
            }
            .disabled(!model.people.speakerMemoryEnabled || !model.people.speakerRuntimeReady)
            Text("只会从保留原音重新计算自动匹配；人工确认、明确拒绝和人物名称不会被覆盖。")
              .font(.caption)
              .foregroundStyle(.secondary)
              .confirmationDialog(
                "删除全部本机声纹向量？",
                isPresented: $confirmSpeakerMemoryDeletion,
                titleVisibility: .visible
              ) {
                Button("删除声纹并关闭记忆", role: .destructive) {
                  model.setSpeakerMemoryEnabled(false)
                }
                Button("取消", role: .cancel) {}
              } message: {
                Text("原音、文字、人物名称和人工确认关系会保留。")
              }
          }
          Section("本机存储") {
            LabeledContent("数据位置") {
              Text(model.localDataLocation)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(2)
            }
            LabeledContent(
              "历史、词典和整理结果",
              value: DictationAppModel.byteCountTitle(model.storageSnapshot.historyBytes)
            )
            LabeledContent(
              "保留的原始音频",
              value: DictationAppModel.byteCountTitle(model.storageSnapshot.sourceAudioBytes)
            )
            LabeledContent(
              "已安装的识别组件",
              value: DictationAppModel.byteCountTitle(model.storageSnapshot.modelBytes)
            )
            LabeledContent(
              "可重新下载缓存",
              value: DictationAppModel.byteCountTitle(
                model.storageSnapshot.rebuildableCacheBytes
              )
            )
            LabeledContent(
              "磁盘可用",
              value: DictationAppModel.byteCountTitle(
                UInt64(max(0, model.storageSnapshot.availableBytes))
              )
            )
            DisclosureGroup("按记录类型查看原音占用") {
              VStack(alignment: .leading, spacing: 7) {
                ForEach(
                  [
                    SessionInputMode.dictation,
                    .roomMicrophone,
                    .systemAudio,
                    .importedMedia,
                  ],
                  id: \.rawValue
                ) { mode in
                  LabeledContent(
                    "\(DictationAppModel.storageModeTitle(mode)) · \(model.history.storageHistoryCounts[mode, default: 0]) 条",
                    value: DictationAppModel.byteCountTitle(
                      model.capture.storageSourceAudioBytes[mode, default: 0]
                    )
                  )
                }
              }
              .padding(.top, 6)
            }
            HStack {
              Button("在 Finder 中显示") { model.revealLocalDataFolder() }
              Button("刷新用量") { model.refreshStorageUsage() }
              Button("清理可重新下载缓存…") {
                confirmRebuildableCacheDeletion = true
              }
              Menu("清空指定类型记录…") {
                ForEach(
                  [
                    SessionInputMode.dictation,
                    .roomMicrophone,
                    .systemAudio,
                    .importedMedia,
                    .userItem,
                  ],
                  id: \.rawValue
                ) { mode in
                  Button(
                    "\(DictationAppModel.storageModeTitle(mode))（\(model.history.storageHistoryCounts[mode, default: 0]) 条）"
                  ) {
                    pendingHistoryClearMode = mode
                  }
                  .disabled(model.history.storageHistoryCounts[mode, default: 0] == 0)
                }
              }
              if model.storageRefreshInProgress {
                ProgressView().controlSize(.small)
              }
            }
            .confirmationDialog(
              pendingHistoryClearMode.map {
                "删除全部\(DictationAppModel.storageModeTitle($0))记录？"
              } ?? "删除记录？",
              isPresented: Binding(
                get: { pendingHistoryClearMode != nil },
                set: { if !$0 { pendingHistoryClearMode = nil } }
              ),
              titleVisibility: .visible
            ) {
              if let mode = pendingHistoryClearMode {
                Button(
                  "删除 \(model.history.storageHistoryCounts[mode, default: 0]) 条记录和保留原音",
                  role: .destructive
                ) {
                  model.clearHistoryRecords(mode: mode)
                  pendingHistoryClearMode = nil
                }
              }
              Button("取消", role: .cancel) { pendingHistoryClearMode = nil }
            } message: {
              Text("这会永久删除该类型的逐字稿、整理结果、人物出现关系和保留原音；其他类型、词典、人物名称和识别组件不会删除。")
            }
            Text(model.storageStatusMessage)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Section("完整备份与恢复") {
            Text(
              "归档覆盖全部可迁移历史、原始音频、逐字稿版本、人物/声纹关系、词典、整理结果和可迁移设置；可重新下载的识别组件、缓存、索引和日志不会写入归档。"
            )
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            SecureField("归档口令（至少 12 个字符）", text: $model.export.archiveSecretDraft)
              .textContentType(.newPassword)
              .accessibilityIdentifier("bestASR.settings.archiveSecret")
            SecureField("再次输入归档口令", text: $model.export.archiveSecretConfirmationDraft)
              .textContentType(.newPassword)
              .accessibilityIdentifier("bestASR.settings.archiveSecretConfirmation")
            HStack {
              Button("导出 .bestasrarchive…") { model.exportPortableArchive() }
                .disabled(
                  !model.archiveSecretIsValid || model.export.archiveOperationInProgress
                )
                .accessibilityIdentifier("bestASR.settings.exportArchive")
              Button("从归档恢复…") { model.importPortableArchive() }
                .disabled(
                  !model.archiveSecretIsValid || model.export.archiveOperationInProgress
                )
                .accessibilityIdentifier("bestASR.settings.importArchive")
              if model.export.archiveOperationInProgress {
                ProgressView().controlSize(.small)
              }
            }
            Text(
              "口令不会保存到钥匙串、日志或归档中。没有来源 Mac 的钥匙串也可在另一台 Mac 恢复；忘记口令则无法解密。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(model.export.archiveStatusMessage)
              .font(.caption)
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("bestASR.settings.archiveStatus")
          }
          Section("隐私诊断") {
            Text(
              "产品遥测和远程崩溃上报默认关闭。诊断摘要只含版本、权限、组件是否就绪和存储总量，不含音频、逐字稿、词典、人物、App 或窗口信息。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
              Button("刷新诊断预览") { model.refreshDiagnosticsPreview() }
              Button("导出诊断摘要…") { model.exportDiagnostics() }
            }
            if !model.diagnosticsPreview.isEmpty {
              Text(model.diagnosticsPreview)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            }
          }
        }
        if selectedCategory == .agents {
          AgentSettingsSections(model: model)
        }
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
      .background(BestASRPalette.canvas)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(.horizontal, 12)
      .padding(.bottom, 12)
    }
    .frame(width: 920, height: 720)
    // A proposal's notification opens this page.
    .onReceive(model.agentAccess.$showAgentSettings) { show in
      guard show, categories.contains(.agents) else { return }
      selectedCategory = .agents
      model.agentAccess.showAgentSettings = false
    }
    .confirmationDialog(
      "清理可重新下载的缓存？",
      isPresented: $confirmRebuildableCacheDeletion,
      titleVisibility: .visible
    ) {
      Button("清理缓存", role: .destructive) {
        model.clearRebuildableCaches()
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("只会删除可重新下载或重新生成的临时缓存；已安装组件、原始音频、逐字稿、人物、事件、词典和设置都会保留。")
    }
    .confirmationDialog(
      "删除这个 App 的专属文字策略？",
      isPresented: Binding(
        get: { pendingAppPolicyDeletion != nil },
        set: { if !$0 { pendingAppPolicyDeletion = nil } }
      ),
      titleVisibility: .visible
    ) {
      if let policy = pendingAppPolicyDeletion {
        Button("删除“\(policy.displayName)”的策略", role: .destructive) {
          pendingAppPolicyDeletion = nil
          model.deleteAppTextPolicy(policy)
        }
      }
      Button("取消", role: .cancel) { pendingAppPolicyDeletion = nil }
    } message: {
      Text("这个 App 将恢复使用默认文字格式；不会删除任何口述、录音、逐字稿或词典。")
    }
  }

  @ViewBuilder
  private func permissionRow(
    _ name: String,
    state: DictationPermissionState,
    open: @escaping () -> Void
  ) -> some View {
    HStack {
      Text(name)
      Spacer()
      Label(
        permissionTitle(state),
        systemImage: state == .granted
          ? "checkmark.circle.fill" : "exclamationmark.circle"
      )
      .foregroundStyle(state == .granted ? Color.green : Color.orange)
      if state == .notDetermined {
        Button("允许", action: open)
      } else if state == .denied || state == .revoked {
        Button("打开系统设置", action: open)
      }
    }
  }

  private func permissionTitle(_ state: DictationPermissionState) -> String {
    switch state {
    case .granted: "已允许"
    case .notDetermined: "尚未允许"
    case .denied: "已拒绝"
    case .restricted: "受系统限制"
    case .revoked: "权限已关闭"
    case .restartRequired: "已允许，重新打开 App 后生效"
    }
  }
}

/// The pairing code for the phone right after "连接 iPhone": a QR code to scan
/// with 织机 on the iPhone, and "复制配对码" to paste there instead. The code
/// holds the phone's private key; closing this window forgets it.
private struct PhonePairingCodeSheet: View {
  let code: String
  let copy: () -> Void
  let done: () -> Void
  @State private var image: CGImage?
  @State private var copied = false

  var body: some View {
    VStack(spacing: 14) {
      Text("用 iPhone 上的织机扫这个码")
        .font(.title3.bold())
      Group {
        if let image {
          Image(decorative: image, scale: 1)
            .interpolation(.none)
            .resizable()
            .scaledToFit()
        } else {
          ProgressView()
        }
      }
      .frame(width: 280, height: 280)
      .accessibilityLabel("配对二维码")
      .accessibilityIdentifier("bestASR.settings.phonePairingCode")
      Text(
        "也可以复制配对码，在 iPhone 的织机里粘贴。配对码里有这台 iPhone 的钥匙，只给你自己的 iPhone 用；关掉这个窗口后，这台 Mac 不再保留它。"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: 320)
      HStack {
        Button(copied ? "已复制" : "复制配对码") {
          copy()
          copied = true
        }
        .accessibilityIdentifier("bestASR.settings.phoneCopyPairingCode")
        Button("完成", action: done)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .task { image = PhonePairingQRCode.image(for: code) }
  }
}
