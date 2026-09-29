#!/bin/zsh
set -eu

repository_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source "$repository_root/script/build_storage.sh"
package_root="$repository_root/Packages/BestASRCore"

swift test \
  --package-path "$package_root" \
  --scratch-path "$BESTASR_SWIFTPM_SCRATCH" \
  --cache-path "$BESTASR_SWIFTPM_CACHE" \
  --filter 'ModelArtifactRegistryTests|ModelDistributionDomainTests|ModelDistributionCoordinatorTests|ModelDownloadTransportTests|DictationTypesTests|DictationSessionActorTests|DictationSilenceDetectorTests|CommittedAudioSnapshotTests|ProductionAudioJournalLiveSnapshotTests|ProductionAudioJournalTests|DictationCaptureCoordinatorTests|DictationProcessingCoordinatorTests|LiveDictationCoordinatorTests|LiveTranscriptRevisionIntegrationTests|CaptureFirstLiveInferenceTests|FinalTranscriptReplacementTests|TypelessDictationRecoveryTests|TypelessDictationPrivacyTests|TypelessDictationMigrationTests|GRDBDictationStoreTests|LiveDictationInsertionIntegrationTests|DictationTargetCompatibilityTests|TextInsertionPolicyTests|NativeGlobalHotkeyProviderTests|MacDictationPermissionServiceTests|AVAudioEngineMicrophoneCaptureTests|RecordingStatusPresentationTests|DictationAccessibilityTests'

"$repository_root/script/privacy_scan.sh"
"$repository_root/script/check_project_drift.sh"

echo "typeless-grade-dictation acceptance: pass"
