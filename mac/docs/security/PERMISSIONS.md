# macOS permission and entitlement contract

bestASR requests protected access only when the user invokes the corresponding feature. The machine-readable source is `config/permissions.json`; `script/lint_permissions.sh` checks it against the committed app Info.plist, the Xcode build settings that select that file, and the app entitlement file.

| Capability | Declaration / check | Request time | Denied behavior |
|---|---|---|---|
| Microphone | `NSMicrophoneUsageDescription`, Hardened Runtime `com.apple.security.device.audio-input`; AVFoundation authorization before device setup | First microphone recording | Keep unrelated features available; show recovery without a prompt loop |
| System audio | `NSAudioCaptureUsageDescription`; Core Audio Process Tap authorization when aggregate-device I/O first starts | First selected-App or whole-Mac recording | Publish or persist no denied audio, clean up any transient tap/aggregate device, retain earlier audio, never widen the source |
| Accessibility | No Info.plist purpose key and no entitlement; `AXIsProcessTrustedWithOptions` | First insertion/enhanced mapping action | Do not read/write another app; retain text and offer manual copy/recovery |

The DMG build currently keeps App Sandbox explicitly disabled pending the Process Tap, Accessibility, import, and XPC matrix. This is not permission bypass: TCC still controls all three capabilities, purpose strings remain mandatory where macOS defines them, and the committed app entitlement plist contains only Hardened Runtime audio input. Xcode base-entitlement injection is disabled so Release signing cannot silently add `get-task-allow`. Network, Apple Events automation, and App Sandbox entitlements are forbidden by the foundation lint. The inference worker has no protected-resource or network entitlement.

`ProcessTapTCCDenialProbe` is a disposable device-lab target with a distinct bundle identifier and its own narrowly scoped usage description. Apple's Process Tap permission prompt occurs when recording starts from the aggregate device, so the probe creates temporary HAL objects, attempts to start I/O, and verifies either an I/O-start rejection or that callbacks contain only digital zero with the fixed synthetic watermark absent. It then requires tap/aggregate counts to return to their pre-run values. The probe starts only the signed synthetic watermark player, persists no audio, and records only OSStatus, callback/frame counts, aggregate signal measurements, and lifecycle counts. A human must explicitly confirm choosing “Don’t Allow” before the conditional observation can become canonical evidence. The workflow never changes the production app's permission entry.

Any future entitlement must name its feature, threat-model impact, runtime and distribution behavior, rollback path, and real-machine evidence before this contract changes.
