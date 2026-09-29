#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repository_root/script/build_storage.sh"
summary_path="$repository_root/artifacts/evidence/environment/check-summary.json"
derived_data_path="$BESTASR_XCODE_DERIVED_DATA"
release_derived_data_path="$BESTASR_XCODE_DERIVED_DATA"
log_root="$BESTASR_BUILD_LOG_ROOT/check"
build_revision="$(git -C "$repository_root" rev-parse HEAD)"

while (( $# > 0 )); do
  case "$1" in
    --summary)
      summary_path="$2"
      shift 2
      ;;
    --derived-data)
      derived_data_path="$2"
      shift 2
      ;;
    --release-derived-data)
      release_derived_data_path="$2"
      shift 2
      ;;
    *)
      print -u2 "error: unknown argument: $1"
      exit 64
      ;;
  esac
done

if [[ -n "${BESTASR_TEST_FAIL_STAGE:-}" || "${BESTASR_TEST_STUB_STAGES:-0}" == "1" ]]; then
  if [[ "${BESTASR_TEST_MODE:-0}" != "1" ]]; then
    print -u2 "error: check-stage overrides require BESTASR_TEST_MODE=1"
    exit 64
  fi
fi

stage_names=(
  bootstrap
  project-regeneration
  static-analysis
  foundation-fixtures
  swift-package-tests
  xcode-build
  unit-tests
  ui-tests
  privacy-scan
  artifact-manifests
)
typeset -A stage_results
for stage_name in "${stage_names[@]}"; do
  stage_results[$stage_name]="not-run"
done

overall_result="running"
failed_stage=""
mkdir -p "$log_root"

write_summary() {
  local summary_directory summary_temp_directory stage_table stages_json summary_temp summary_stage_name
  summary_directory="$(dirname "$summary_path")"
  mkdir -p "$summary_directory"
  summary_temp_directory="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-check-summary.XXXXXX")"
  stage_table="$summary_temp_directory/stages.tsv"
  stages_json="$summary_temp_directory/stages.json"
  summary_temp="$summary_temp_directory/check-summary.json"
  trap 'rm -f "$stage_table" "$stages_json" "$summary_temp"; rmdir "$summary_temp_directory" 2>/dev/null || true' EXIT

  for summary_stage_name in "${stage_names[@]}"; do
    printf '%s\t%s\n' "$summary_stage_name" "${stage_results[$summary_stage_name]}" >> "$stage_table"
  done
  jq -Rn '[inputs | split("\t") | {name: .[0], status: .[1]}]' "$stage_table" > "$stages_json"
  jq -n \
    --arg status "$overall_result" \
    --arg failedStage "$failed_stage" \
    --arg derivedDataKind "external-volume" \
    --slurpfile stages "$stages_json" \
    '{
      schemaVersion: 1,
      status: $status,
      failedStage: $failedStage,
      derivedDataKind: $derivedDataKind,
      stages: $stages[0]
    }' > "$summary_temp"

  mv "$summary_temp" "$summary_path"
  rm -f "$stage_table" "$stages_json"
  rmdir "$summary_temp_directory"
  trap - EXIT
}

xcode_arguments=(
  -workspace "$repository_root/BestASR.xcworkspace"
  -scheme BestASR
  -configuration Debug
  -destination 'platform=macOS,arch=arm64'
  -derivedDataPath "$derived_data_path"
  -clonedSourcePackagesDirPath "$BESTASR_XCODE_SOURCE_PACKAGES"
  -packageCachePath "$BESTASR_XCODE_PACKAGE_CACHE"
  -disablePackageRepositoryCache
  -skipPackageUpdates
  ARCHS=arm64
  ONLY_ACTIVE_ARCH=YES
  BESTASR_GIT_REVISION="$build_revision"
)

release_xcode_arguments=(
  -workspace "$repository_root/BestASR.xcworkspace"
  -scheme BestASR
  -configuration Release
  -destination 'platform=macOS,arch=arm64'
  -derivedDataPath "$release_derived_data_path"
  -clonedSourcePackagesDirPath "$BESTASR_XCODE_SOURCE_PACKAGES"
  -packageCachePath "$BESTASR_XCODE_PACKAGE_CACHE"
  -disablePackageRepositoryCache
  -skipPackageUpdates
  ARCHS=arm64
  ONLY_ACTIVE_ARCH=YES
  BESTASR_GIT_REVISION="$build_revision"
)

execute_stage() {
  local stage_name="$1"
  case "$stage_name" in
    bootstrap)
      "$repository_root/script/bootstrap.sh"
      ;;
    project-regeneration)
      "$repository_root/script/check_project_drift.sh"
      ;;
    static-analysis)
      "$repository_root/script/lint.sh"
      ;;
    foundation-fixtures)
      "$repository_root/Tests/Shell/bootstrap_tests.sh"
      "$repository_root/Tests/Shell/artifact_manifest_tests.sh"
      "$repository_root/Tests/Shell/privacy_scan_tests.sh"
      "$repository_root/Tests/Shell/check_pipeline_tests.sh"
      "$repository_root/Tests/Shell/environment_gate_tests.sh"
      "$repository_root/Tests/Shell/corpus_manifest_tests.sh"
      "$repository_root/Tests/Shell/permission_lint_tests.sh"
      "$repository_root/Tests/Shell/supply_chain_tests.sh"
      "$repository_root/Tests/Shell/traceability_tests.sh"
      python3 "$repository_root/Tests/Shell/delivery_contract_tests.py"
      "$repository_root/Tests/Shell/product_consistency_tests.sh"
      "$repository_root/Tests/Shell/readiness_report_tests.sh"
      "$repository_root/Tests/Shell/dictation_alpha_readiness_tests.sh"
      "$repository_root/Tests/Shell/dictation_alpha_target_tests.sh"
      "$repository_root/Tests/Shell/inference_evidence_tests.sh"
      "$repository_root/Tests/Shell/builtin_microphone_evidence_tests.sh"
      "$repository_root/Tests/Shell/local_text_evidence_tests.sh"
      "$repository_root/Tests/Shell/audio_decision_tests.sh"
      "$repository_root/Tests/Shell/build_storage_tests.sh"
      "$repository_root/Tests/Shell/install_local_app_tests.sh"
      "$repository_root/Tests/Shell/unregister_build_app_tests.sh"
      ;;
    swift-package-tests)
      SWIFTPM_MODULECACHE_OVERRIDE="$BESTASR_SWIFTPM_MODULE_CACHE" \
        CLANG_MODULE_CACHE_PATH="$BESTASR_CLANG_MODULE_CACHE" \
      swift test \
          --package-path "$repository_root/Packages/BestASRCore" \
          --scratch-path "$BESTASR_SWIFTPM_SCRATCH" \
          --cache-path "$BESTASR_SWIFTPM_CACHE"
      "$repository_root/script/run_dictation_fixture_harness.sh" \
        --scratch-path "$BESTASR_SWIFTPM_SCRATCH"
      swift run \
        --package-path "$repository_root/Packages/BestASRCore" \
        --scratch-path "$BESTASR_SWIFTPM_SCRATCH" \
        --cache-path "$BESTASR_SWIFTPM_CACHE" \
        ModelManagerProbeCLI \
        --summary "$repository_root/artifacts/evidence/supply-chain/model-activation-summary.json"
      "$repository_root/script/run_offline_smoke.sh" \
        --scratch-path "$BESTASR_SWIFTPM_SCRATCH" \
        --summary "$repository_root/artifacts/evidence/privacy/offline-smoke-summary.json"
      swift run \
        --package-path "$repository_root/Packages/BestASRCore" \
        --scratch-path "$BESTASR_SWIFTPM_SCRATCH" \
        --cache-path "$BESTASR_SWIFTPM_CACHE" \
        PersistenceMigrationProbeCLI \
        --summary "$repository_root/artifacts/evidence/persistence/migration-summary.json"
      swift run \
        --package-path "$repository_root/Packages/BestASRCore" \
        --scratch-path "$BESTASR_SWIFTPM_SCRATCH" \
        --cache-path "$BESTASR_SWIFTPM_CACHE" \
        CrossRootMigrationProbeCLI \
        --summary "$repository_root/artifacts/evidence/persistence/cross-root-roundtrip-summary.json"
      swift run \
        --package-path "$repository_root/Packages/BestASRCore" \
        --scratch-path "$BESTASR_SWIFTPM_SCRATCH" \
        --cache-path "$BESTASR_SWIFTPM_CACHE" \
        PortableMigrationProbeCLI \
        --summary "$repository_root/artifacts/evidence/SPIKE-MIG-001/summary.json" \
        --matrix "$repository_root/artifacts/evidence/SPIKE-MIG-001/matrix.json"
      "$repository_root/script/run_audio_timeline_probe.sh"
      "$repository_root/script/run_audio_journal_probe.sh"
      "$repository_root/script/run_inference_queue_probe.sh"
      "$repository_root/script/run_xpc_probe.sh"
      "$repository_root/script/run_candidate_adapter_probe.sh"
      "$repository_root/script/run_llm_factual_gate_probe.sh"
      "$repository_root/script/run_resource_policy_probe.sh"
      "$repository_root/script/run_update_rollback_probe.sh"
      "$repository_root/script/run_text_insertion_policy_probe.sh"
      ;;
    xcode-build)
      xcodebuild "${xcode_arguments[@]}" build-for-testing
      "$repository_root/script/verify_built_permissions.sh" \
        --app "$derived_data_path/Build/Products/Debug/bestASR.app"
      xcodebuild "${release_xcode_arguments[@]}" build
      "$repository_root/script/generate_supply_chain.sh" \
        --package "$release_derived_data_path/Build/Products/Release/bestASR.app"
      "$repository_root/script/run_release_smoke.sh" \
        --app "$release_derived_data_path/Build/Products/Release/bestASR.app"
      ;;
    unit-tests)
      xcodebuild "${xcode_arguments[@]}" \
        -parallel-testing-enabled NO \
        test-without-building \
        -only-testing:WorkspaceSmokeTests \
        -only-testing:BestASRAppTests
      ;;
    ui-tests)
      xcodebuild "${xcode_arguments[@]}" \
        -parallel-testing-enabled NO \
        test-without-building \
        -only-testing:BestASRUITests
      ;;
    privacy-scan)
      "$repository_root/script/privacy_scan.sh"
      ;;
    artifact-manifests)
      "$repository_root/script/validate_artifacts.sh"
      "$repository_root/script/validate_release_package.sh" \
        --package "$release_derived_data_path/Build/Products/Release/bestASR.app"
      "$repository_root/script/validate_release_evidence.sh"
      "$repository_root/script/validate_traceability.sh"
      python3 "$repository_root/script/delivery_contract_evidence.py" --validate \
        --summary "$repository_root/artifacts/evidence/text-delivery/contract-summary.json"
      "$repository_root/script/validate_product_consistency.sh"
      "$repository_root/script/validate_local_text_evidence.sh"
      "$repository_root/script/validate_builtin_microphone_evidence.sh"
      "$repository_root/script/validate_dictation_alpha_targets.sh"
      "$repository_root/script/validate_inference_evidence.sh"
      "$repository_root/script/validate_audio_decision.sh"
      "$repository_root/script/validate_corpus_manifests.sh"
      "$repository_root/script/check_corpus_git_safety.sh" --include-untracked
      ;;
    *)
      print -u2 "error: unknown stage: $stage_name"
      return 64
      ;;
  esac
}

for stage_name in "${stage_names[@]}"; do
  print "==> $stage_name"
  log_path="$log_root/$stage_name.log"
  stage_results[$stage_name]="running"

  set +e
  if [[ "${BESTASR_TEST_FAIL_STAGE:-}" == "$stage_name" ]]; then
    print "injected failure for $stage_name" > "$log_path"
    stage_exit_code=97
  elif [[ "${BESTASR_TEST_STUB_STAGES:-0}" == "1" ]]; then
    print "stubbed pass for $stage_name" > "$log_path"
    stage_exit_code=0
  else
    execute_stage "$stage_name" > "$log_path" 2>&1
    stage_exit_code=$?
  fi
  set -e

  if (( stage_exit_code != 0 )); then
    stage_results[$stage_name]="fail"
    overall_result="fail"
    failed_stage="$stage_name"
    write_summary
    "$repository_root/script/generate_engineering_readiness.sh" >/dev/null 2>&1 || true
    "$repository_root/script/generate_dictation_alpha_readiness.sh" >/dev/null 2>&1 || true
    print -u2 "check failed at stage: $stage_name"
    /usr/bin/tail -n 80 "$log_path" >&2
    print -u2 "summary: $summary_path"
    exit "$stage_exit_code"
  fi

  stage_results[$stage_name]="pass"
done

overall_result="pass"
write_summary
"$repository_root/script/generate_engineering_readiness.sh"
"$repository_root/script/generate_dictation_alpha_readiness.sh"
print "all repository checks passed"
print "summary: $summary_path"
