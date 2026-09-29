#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
registry_path="$repository_root/config/inference-candidates.json"
speaker_registry_path="$repository_root/config/speaker-candidates.json"
asr_contract_path="$repository_root/artifacts/evidence/SPIKE-ASR-001/adapter-contract-smoke.json"
asr_recommended_smoke_path="$repository_root/artifacts/evidence/SPIKE-ASR-001/recommended-memory-smoke-summary.json"
asr_alpha_benchmark_path="$repository_root/artifacts/evidence/SPIKE-ASR-001/fluid-sensevoice-alpha-corpus.json"
asr_alpha_decision_path="$repository_root/artifacts/evidence/SPIKE-ASR-001/fluid-sensevoice-alpha-decision.json"
asr_alpha_corpus_path="$repository_root/Corpus/product-synthetic/alpha-asr-manifest.json"
corpus_manifest_path="$repository_root/Corpus/product-synthetic/manifest.json"
speaker_corpus_manifest_path="$repository_root/Corpus/product-synthetic/speaker-manifest.json"
speaker_recommended_smoke_path="$repository_root/artifacts/evidence/SPIKE-SPK-001/recommended-memory-synthetic-smoke-summary.json"
speaker_ami_tuning_manifest_path="$repository_root/Corpus/public/ami-speaker-manifest.json"
speaker_ami_release_manifest_path="$repository_root/Corpus/release-holdout/ami-speaker-manifest.json"
speaker_ami_tuning_benchmark_path="$repository_root/artifacts/evidence/SPIKE-SPK-001/fluid-ami-tuning-benchmark.json"
speaker_ami_tuning_decision_path="$repository_root/artifacts/evidence/SPIKE-SPK-001/fluid-ami-tuning-decision.json"
speaker_ami_release_benchmark_path="$repository_root/artifacts/evidence/SPIKE-SPK-001/fluid-ami-release-holdout-benchmark.json"
speaker_ami_release_decision_path="$repository_root/artifacts/evidence/SPIKE-SPK-001/fluid-ami-release-holdout-decision.json"
llm_matrix_path="$repository_root/artifacts/evidence/SPIKE-LLM-001/matrix.json"
resource_matrix_path="$repository_root/artifacts/evidence/SPIKE-RES-001/matrix.json"
installed_model_dictation_path="$repository_root/artifacts/evidence/privacy/installed-model-dictation-summary.json"
summary_path="$repository_root/artifacts/evidence/benchmark/inference-evidence-integrity.json"

while (( $# > 0 )); do
  case "$1" in
    --registry) registry_path="$2"; shift 2 ;;
    --speaker-registry) speaker_registry_path="$2"; shift 2 ;;
    --asr-contract) asr_contract_path="$2"; shift 2 ;;
    --asr-recommended-smoke) asr_recommended_smoke_path="$2"; shift 2 ;;
    --asr-alpha-benchmark) asr_alpha_benchmark_path="$2"; shift 2 ;;
    --asr-alpha-decision) asr_alpha_decision_path="$2"; shift 2 ;;
    --asr-alpha-corpus) asr_alpha_corpus_path="$2"; shift 2 ;;
    --corpus-manifest) corpus_manifest_path="$2"; shift 2 ;;
    --speaker-corpus-manifest) speaker_corpus_manifest_path="$2"; shift 2 ;;
    --speaker-recommended-smoke) speaker_recommended_smoke_path="$2"; shift 2 ;;
    --llm-matrix) llm_matrix_path="$2"; shift 2 ;;
    --resource-matrix) resource_matrix_path="$2"; shift 2 ;;
    --installed-model-dictation) installed_model_dictation_path="$2"; shift 2 ;;
    --summary) summary_path="$2"; shift 2 ;;
    *) print -u2 "error: unknown argument: $1"; exit 64 ;;
  esac
done

for required_tool in jq shasum; do
  command -v "$required_tool" >/dev/null 2>&1 || {
    print -u2 "error: required inference evidence tool missing: $required_tool"
    exit 2
  }
done

validation_status="pass"
failure_category=""
missing_reports=()

write_summary() {
  local temporary_root temporary_summary missing_json
  temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-inference-integrity.XXXXXX")"
  temporary_summary="$temporary_root/summary.json"
  missing_json="$(printf '%s\n' "${missing_reports[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  mkdir -p "$(dirname "$summary_path")"
  jq -n \
    --arg status "$validation_status" \
    --arg failureCategory "$failure_category" \
    --arg selectionState "$(
      if (( ${#missing_reports[@]} > 0 )); then
        print -r -- "alpha-default-selected-release-blocked"
      else
        print -r -- "ready-for-explicit-decision"
      fi
    )" \
    --argjson missingReports "$missing_json" \
    '{
      schemaVersion: 1,
      kind: "inference-evidence-integrity",
      status: $status,
      failureCategory: $failureCategory,
      selectionState: $selectionState,
      missingReports: $missingReports
    }' > "$temporary_summary"
  mv "$temporary_summary" "$summary_path"
  rmdir "$temporary_root"
}

fail_validation() {
  failure_category="$1"
  validation_status="fail"
  write_summary
  print -u2 "inference evidence validation failed: $failure_category"
  exit 1
}

for required_file in \
  "$registry_path" \
  "$speaker_registry_path" \
  "$asr_contract_path" \
  "$asr_recommended_smoke_path" \
  "$asr_alpha_benchmark_path" \
  "$asr_alpha_decision_path" \
  "$asr_alpha_corpus_path" \
  "$corpus_manifest_path" \
  "$speaker_corpus_manifest_path" \
  "$speaker_recommended_smoke_path" \
  "$speaker_ami_tuning_manifest_path" \
  "$speaker_ami_release_manifest_path" \
  "$speaker_ami_tuning_benchmark_path" \
  "$speaker_ami_tuning_decision_path" \
  "$speaker_ami_release_benchmark_path" \
  "$speaker_ami_release_decision_path" \
  "$llm_matrix_path" \
  "$resource_matrix_path" \
  "$installed_model_dictation_path"
do
  [[ -f "$required_file" ]] || fail_validation "required-input-missing"
done

registry_digest="$(shasum -a 256 "$registry_path" | awk '{print $1}')"
fixture_digest="$(shasum -a 256 "$repository_root/Tests/Fixtures/CandidateAdapters/contract-cases.json" | awk '{print $1}')"
llm_fixture_digest="$(shasum -a 256 "$repository_root/Tests/Fixtures/LocalText/factual-gate-suite.json" | awk '{print $1}')"

[[ "$(jq -r '.manifestSHA256' "$asr_contract_path")" == "$registry_digest" ]] \
  || fail_validation "asr-registry-digest-mismatch"
[[ "$(jq -r '.fixtureSuiteSHA256' "$asr_contract_path")" == "$fixture_digest" ]] \
  || fail_validation "asr-fixture-digest-mismatch"
[[ "$(jq -r '.fixtureSHA256' "$llm_matrix_path")" == "$llm_fixture_digest" ]] \
  || fail_validation "llm-fixture-digest-mismatch"

registry_ids="$(jq -c '[.candidates[].candidateID] | sort' "$registry_path")"
report_ids="$(jq -c '[.candidates[].candidateID] | sort' "$asr_contract_path")"
recommended_smoke_ids="$(jq -c '[.candidates[].candidateID] | sort' "$asr_recommended_smoke_path")"
[[ "$registry_ids" == "$report_ids" ]] \
  || fail_validation "candidate-set-mismatch"
[[ "$registry_ids" == "$recommended_smoke_ids" ]] \
  || fail_validation "recommended-memory-candidate-set-mismatch"

alpha_candidate_count="$(jq '[.candidates[] | select(.alphaDefault == true)] | length' "$registry_path")"
[[ "$alpha_candidate_count" == "1" ]] \
  || fail_validation "alpha-default-count-invalid"
alpha_candidate_id="$(jq -r '.candidates[] | select(.alphaDefault == true) | .candidateID' "$registry_path")"
[[ "$alpha_candidate_id" == "fluid-sensevoice" ]] \
  || fail_validation "alpha-default-candidate-invalid"

for alpha_evidence_path in \
  "$(jq -r --arg id "$alpha_candidate_id" '.candidates[] | select(.candidateID == $id) | .alphaEvidence.benchmarkResultPath' "$registry_path")" \
  "$(jq -r --arg id "$alpha_candidate_id" '.candidates[] | select(.candidateID == $id) | .alphaEvidence.decisionPath' "$registry_path")" \
  "$(jq -r --arg id "$alpha_candidate_id" '.candidates[] | select(.candidateID == $id) | .alphaEvidence.corpusManifestPath' "$registry_path")"
do
  [[ "$alpha_evidence_path" != /* \
    && "/$alpha_evidence_path/" != *"/../"* \
    && "/$alpha_evidence_path/" != *"/./"* ]] \
    || fail_validation "unsafe-alpha-evidence-path"
done

alpha_benchmark_digest="$(shasum -a 256 "$asr_alpha_benchmark_path" | awk '{print $1}')"
alpha_decision_digest="$(shasum -a 256 "$asr_alpha_decision_path" | awk '{print $1}')"
alpha_corpus_digest="$(shasum -a 256 "$asr_alpha_corpus_path" | awk '{print $1}')"
expected_alpha_benchmark_digest="$(jq -r --arg id "$alpha_candidate_id" '.candidates[] | select(.candidateID == $id) | .alphaEvidence.benchmarkResultSHA256' "$registry_path")"
expected_alpha_decision_digest="$(jq -r --arg id "$alpha_candidate_id" '.candidates[] | select(.candidateID == $id) | .alphaEvidence.decisionSHA256' "$registry_path")"
expected_alpha_corpus_digest="$(jq -r --arg id "$alpha_candidate_id" '.candidates[] | select(.candidateID == $id) | .alphaEvidence.corpusManifestSHA256' "$registry_path")"
[[ "$alpha_benchmark_digest" == "$expected_alpha_benchmark_digest" \
  && "$alpha_decision_digest" == "$expected_alpha_decision_digest" \
  && "$alpha_corpus_digest" == "$expected_alpha_corpus_digest" ]] \
  || fail_validation "alpha-evidence-digest-mismatch"

expected_alpha_artifact_id="$(jq -r --arg id "$alpha_candidate_id" '.candidates[] | select(.candidateID == $id) | .probeArtifact.realModelEvidence.artifactID' "$registry_path")"
expected_alpha_model_digest="$(jq -r --arg id "$alpha_candidate_id" '.candidates[] | select(.candidateID == $id) | .probeArtifact.realModelEvidence.treeSHA256' "$registry_path")"
expected_alpha_runtime_revision="$(jq -r --arg id "$alpha_candidate_id" '.candidates[] | select(.candidateID == $id) | .upstreamRuntime.revision' "$registry_path")"
expected_alpha_model_version="$(jq -r --arg id "$expected_alpha_artifact_id" '.models[] | select(.id == $id) | .exactVersion' "$repository_root/config/model-artifacts.json")"
jq -e \
  --arg artifactID "$expected_alpha_artifact_id" \
  --arg modelDigest "$expected_alpha_model_digest" \
  --arg runtimeRevision "$expected_alpha_runtime_revision" '
  .schemaVersion == 1 and
  .kind == "benchmark-result" and
  .task == "asr" and
  .implementationRevision == $runtimeRevision and
  .modelArtifact == {artifactID: $artifactID, sha256: $modelDigest} and
  .corpus == {
    manifestID: "product-synthetic-alpha-asr-v1",
    version: "1.1.0",
    split: "tuning"
  } and
  (.failedSampleUUIDs | length == 0) and
  ([.metrics[].name] | contains([
    "cer", "wer", "mer", "dangerous-token-errors",
    "latency-p95", "realtime-factor", "peak-rss"
  ]))
  ' "$asr_alpha_benchmark_path" >/dev/null \
  || fail_validation "alpha-benchmark-contract-invalid"

jq -e \
  --arg artifactID "$expected_alpha_artifact_id" \
  --arg modelDigest "$expected_alpha_model_digest" '
  .schemaVersion == 1 and
  .kind == "alpha-asr-evaluation-decision" and
  .status == "pass" and
  .selectionEligible == true and
  .corpusManifestID == "product-synthetic-alpha-asr-v1" and
  .corpusVersion == "1.1.0" and
  .sampleCount == 16 and
  .modelArtifact == {artifactID: $artifactID, sha256: $modelDigest} and
  .networkDeniedByParentSandbox == true and
  (.failedSampleUUIDs | length == 0) and
  all(.gates[]; .status == "pass") and
  ([.requiredTags] | flatten | contains([
    "english", "mandarin", "mixed-language", "names-terms",
    "numbers-dates-negation", "pace", "self-correction", "silence"
  ]))
  ' "$asr_alpha_decision_path" >/dev/null \
  || fail_validation "alpha-decision-contract-invalid"

jq -e \
  --arg artifactID "$expected_alpha_artifact_id" \
  --arg modelVersion "$expected_alpha_model_version" '
  .schemaVersion == 6 and
  .kind == "installed-model-dictation-probe" and
  .status == "pass" and
  .appVersion == "0.1.0" and
  .buildConfiguration == "release" and
  .networkDeniedByParentSandbox == true and
  .modelArtifactID == $artifactID and
  .modelVersion == $modelVersion and
  (.modelActivation == "activated" or
    .modelActivation == "alreadyActive" or
    .modelActivation == "repaired") and
  .polishModelArtifactID == "qwen3-1.7b-mlx-4bit-21457c6f" and
  .polishModelVersion == "21457c6f51ed54a7c16e988c0844db973815c137" and
  .polishModelTreeSHA256 == "09570edbadcacc0bb3abc5c58d688f92978cd62601cf98e11cf38356fd5bd7be" and
  (.polishModelActivation == "activated" or
    .polishModelActivation == "alreadyActive" or
    .polishModelActivation == "repaired") and
  .finalPhase == "completed" and
  .sourceAudioRangeCount > 0 and
  .sourceAudioPreserved == true and
  .transcriptCharacterCount > 0 and
  .transcriptSegmentCount > 0 and
  .polishDisposition == "model" and
  .insertionMethod == "retainedForCopy" and
  .externalInsertionPerformed == false and
  .dictionaryEntryCount == 1 and
  .sessionSpeakerCount == 1 and
  .speakerOccurrenceCount == .sourceAudioRangeCount and
  .speakerJobState == "queued" and
  .firstRunToReadyMilliseconds > 0 and
  .readyToFirstLiveTextMilliseconds > 0 and
  .finishToFinalTextMilliseconds > 0 and
  .liveTranscriptCharacterCount > 0 and
  .maximumLiveQueueDepth >= 0 and
  .maximumLiveQueueDepth <= 1 and
  .offlineRelaunchReady == true and
  .recoveryOutcome == "sealed-source-readable" and
  .asrProcessingMilliseconds > 0 and
  .postASRProcessingMilliseconds > 0 and
  .pipelineOverheadMilliseconds >= 0 and
  .dictationProcessingMilliseconds > 0 and
  ((.asrProcessingMilliseconds + .postASRProcessingMilliseconds +
    .pipelineOverheadMilliseconds) - .dictationProcessingMilliseconds | abs) < 0.01 and
  .firstRunToReadyMilliseconds < .elapsedMilliseconds and
  .dictationProcessingMilliseconds < .elapsedMilliseconds and
  .peakRSSBytes > 0 and
  ([.. | objects | keys[]] | any(
    . == "text" or
    . == "transcript" or
    . == "dictionaryTerms" or
    . == "absolutePath" or
    . == "audioPath"
  ) | not)
  ' "$installed_model_dictation_path" >/dev/null \
  || fail_validation "installed-model-dictation-contract-invalid"

jq -e \
  --arg digest "$alpha_corpus_digest" '
  .selectionStatus == "alpha-default-selected-from-local-corpus" and
  ([.candidates[] | select(.alphaDefault == true)] | length == 1) and
  all(.candidates[]; .releaseEligible == false) and
  any(.candidates[];
    .candidateID == "fluid-sensevoice" and
    .alphaDefault == true and
    .alphaEvidence.corpusManifestID == "product-synthetic-alpha-asr-v1" and
    .alphaEvidence.corpusVersion == "1.1.0" and
    .alphaEvidence.sampleCount == 16 and
    .alphaEvidence.networkDenied == true and
    .alphaEvidence.corpusManifestSHA256 == $digest
  )
  ' "$registry_path" >/dev/null \
  || fail_validation "alpha-selection-reference-invalid"

corpus_manifest_digest="$(shasum -a 256 "$corpus_manifest_path" | awk '{print $1}')"
jq -e \
  --arg corpusDigest "$corpus_manifest_digest" '
  .conclusion == "conditional-recommended-memory-smoke-only" and
  .releaseEligible == false and
  .selectionDecision == "no-default-candidate-selected" and
  .scope.deviceClass == "recommended-memory-development-host" and
  .scope.architecture == "arm64" and
  (.scope.unifiedMemoryBytes >= 17179869184) and
  .scope.networkDeniedDuringInference == true and
  .corpus.manifestID == "product-synthetic-smoke" and
  .corpus.version == "1.1.0" and
  .corpus.manifestSHA256 == $corpusDigest and
  .corpus.sampleCount == 3 and
  (.unmetReleaseCriteria | length > 0)
  ' "$asr_recommended_smoke_path" >/dev/null \
  || fail_validation "recommended-memory-summary-invalid"

while IFS= read -r candidate_id; do
  artifact_path="$(jq -r --arg id "$candidate_id" '.candidates[] | select(.candidateID == $id) | .probeArtifact.relativePath' "$registry_path")"
  [[ "$artifact_path" != /* \
    && "/$artifact_path/" != *"/../"* \
    && "/$artifact_path/" != *"/./"* ]] \
    || fail_validation "unsafe-candidate-artifact-path"
  expected_digest="$(jq -r --arg id "$candidate_id" '.candidates[] | select(.candidateID == $id) | .probeArtifact.sha256' "$registry_path")"
  reported_digest="$(jq -r --arg id "$candidate_id" '.candidates[] | select(.candidateID == $id) | .artifactSHA256' "$asr_contract_path")"
  [[ -f "$repository_root/$artifact_path" ]] \
    || fail_validation "candidate-artifact-missing"
  actual_digest="$(shasum -a 256 "$repository_root/$artifact_path" | awk '{print $1}')"
  [[ "$expected_digest" == "$actual_digest" \
    && "$reported_digest" == "$actual_digest" ]] \
    || fail_validation "candidate-artifact-digest-mismatch"
done < <(jq -r '.candidates[].candidateID' "$registry_path")

while IFS= read -r candidate_id; do
  result_path="$(jq -r --arg id "$candidate_id" \
    '.candidates[] | select(.candidateID == $id) | .probeArtifact.realModelEvidence.benchmarkResultPath' \
    "$registry_path")"
  [[ "$result_path" != /* \
    && "/$result_path/" != *"/../"* \
    && "/$result_path/" != *"/./"* ]] \
    || fail_validation "unsafe-recommended-memory-result-path"
  [[ -f "$repository_root/$result_path" ]] \
    || fail_validation "recommended-memory-result-missing"

  expected_result_digest="$(jq -r --arg id "$candidate_id" \
    '.candidates[] | select(.candidateID == $id) | .probeArtifact.realModelEvidence.benchmarkResultSHA256' \
    "$registry_path")"
  actual_result_digest="$(shasum -a 256 "$repository_root/$result_path" | awk '{print $1}')"
  [[ "$expected_result_digest" == "$actual_result_digest" ]] \
    || fail_validation "recommended-memory-result-digest-mismatch"

  expected_runtime_revision="$(jq -r --arg id "$candidate_id" \
    '.candidates[] | select(.candidateID == $id) | .upstreamRuntime.revision' \
    "$registry_path")"
  expected_artifact_id="$(jq -r --arg id "$candidate_id" \
    '.candidates[] | select(.candidateID == $id) | .probeArtifact.realModelEvidence.artifactID' \
    "$registry_path")"
  expected_model_digest="$(jq -r --arg id "$candidate_id" \
    '.candidates[] | select(.candidateID == $id) | .probeArtifact.realModelEvidence.treeSHA256' \
    "$registry_path")"
  expected_memory="$(jq -r '.scope.unifiedMemoryBytes' "$asr_recommended_smoke_path")"

  jq -e \
    --arg runtimeRevision "$expected_runtime_revision" \
    --arg artifactID "$expected_artifact_id" \
    --arg modelDigest "$expected_model_digest" \
    --argjson unifiedMemoryBytes "$expected_memory" '
    .kind == "benchmark-result" and
    .task == "asr" and
    .protocolVersion == 1 and
    .implementationRevision == $runtimeRevision and
    .modelArtifact.artifactID == $artifactID and
    .modelArtifact.sha256 == $modelDigest and
    .corpus == {
      manifestID: "product-synthetic-smoke",
      version: "1.1.0",
      split: "smoke"
    } and
    .hardware.architecture == "arm64" and
    .hardware.unifiedMemoryBytes == $unifiedMemoryBytes and
    ([.metrics[].name] | contains([
      "cer",
      "wer",
      "mer",
      "dangerous-token-errors",
      "dangerous-token-errors.action-owner",
      "dangerous-token-errors.date",
      "dangerous-token-errors.negation",
      "dangerous-token-errors.number",
      "dangerous-token-errors.person",
      "latency-p50",
      "latency-p95",
      "realtime-factor",
      "peak-rss",
      "backlog-high-watermark"
    ]))
    ' "$repository_root/$result_path" >/dev/null \
    || fail_validation "recommended-memory-result-contract-invalid"

  jq -e \
    --arg id "$candidate_id" \
    --arg resultPath "$result_path" \
    --arg resultDigest "$actual_result_digest" \
    --arg runtimeRevision "$expected_runtime_revision" \
    --arg artifactID "$expected_artifact_id" \
    --arg modelDigest "$expected_model_digest" '
    any(.candidates[];
      .candidateID == $id and
      .benchmarkResultPath == $resultPath and
      .benchmarkResultSHA256 == $resultDigest and
      .runtimeRevision == $runtimeRevision and
      .modelArtifactID == $artifactID and
      .modelTreeSHA256 == $modelDigest
    )
    ' "$asr_recommended_smoke_path" >/dev/null \
    || fail_validation "recommended-memory-summary-reference-mismatch"
done < <(jq -r '.candidates[].candidateID' "$registry_path")

speaker_registry_digest="$(shasum -a 256 "$speaker_registry_path" | awk '{print $1}')"
speaker_corpus_manifest_digest="$(shasum -a 256 "$speaker_corpus_manifest_path" | awk '{print $1}')"

jq -e '
  .schemaVersion == 1 and
  .kind == "speaker-candidate-registry" and
  .selectionStatus == "fluid-public-holdout-selected-production-candidate-16gb-release-gate-pending" and
  .minimumSupportedUnifiedMemoryBytes >= 17179869184 and
  .networkPolicy == "model-manager-verified-artifacts-only" and
  ([.candidates[].candidateID] | sort) == ["argmax", "fluid", "sherpa"] and
  all(.candidates[];
    (.upstreamRuntime.revision | test("^[0-9a-f]{40}$")) and
    (.modelArtifact.treeSHA256 | test("^[0-9a-f]{64}$")) and
    (.modelArtifact.fileCount > 0) and
    (.modelArtifact.totalSizeBytes > 0) and
    (.modelArtifact.license | length > 0) and
    (.modelArtifact.licenseStatus | length > 0) and
    (.supportedArchitectures | index("arm64") != null) and
    (.capabilities | index("speaker.diarization") != null) and
    (.capabilities | index("speaker.embedding") != null) and
    (.evidence.automaticBenchmarkResultPath | startswith("artifacts/evidence/SPIKE-SPK-001/")) and
    (.evidence.automaticBenchmarkResultSHA256 | test("^[0-9a-f]{64}$")) and
    (.evidence.oracleBenchmarkResultPath | startswith("artifacts/evidence/SPIKE-SPK-001/")) and
    (.evidence.oracleBenchmarkResultSHA256 | test("^[0-9a-f]{64}$")) and
    (.evidence.identityEvaluationSHA256 | test("^[0-9a-f]{64}$")) and
    .evidence.identityEvaluationStorage == "external-local-only" and
    .evidence.networkDenied == true and
    (.evidence.executionProvider | length > 0) and
    .releaseEligible == false
  ) and
  ([.candidates[] | select(.frozenProductionCandidate == true) | .candidateID] == ["fluid"]) and
  (.candidates[] | select(.candidateID == "fluid") | .evidence.publicReleaseHoldout |
    .selectionEligible == true and
    .networkDenied == true and
    .minimumHardwareGate == "pending-16gb-apple-silicon" and
    (.modelArtifactID | length > 0) and
    (.modelTreeSHA256 | test("^[0-9a-f]{64}$")) and
    (.thresholdPolicy | length > 0) and
    (.threshold >= -1 and .threshold <= 1) and
    .evaluatedUnifiedMemoryBytes == 51539607552
  )
  ' "$speaker_registry_path" >/dev/null \
  || fail_validation "speaker-registry-invalid"

fluid_release_evidence_prefix='.candidates[] | select(.candidateID == "fluid") | .evidence.publicReleaseHoldout'
for evidence_key in \
  tuningCorpusManifest \
  releaseCorpusManifest \
  tuningBenchmarkResult \
  tuningDecision \
  releaseBenchmarkResult \
  releaseDecision
do
  path_key="${evidence_key}Path"
  digest_key="${evidence_key}SHA256"
  evidence_path="$(jq -r --arg key "$path_key" '
    .candidates[]
    | select(.candidateID == "fluid")
    | .evidence.publicReleaseHoldout[$key]
    ' "$speaker_registry_path")"
  expected_digest="$(jq -r --arg key "$digest_key" '
    .candidates[]
    | select(.candidateID == "fluid")
    | .evidence.publicReleaseHoldout[$key]
    ' "$speaker_registry_path")"
  [[ "$evidence_path" != /* \
    && "/$evidence_path/" != *"/../"* \
    && "/$evidence_path/" != *"/./"* ]] \
    || fail_validation "unsafe-speaker-release-evidence-path"
  [[ -f "$repository_root/$evidence_path" ]] \
    || fail_validation "speaker-release-evidence-missing"
  [[ "$(shasum -a 256 "$repository_root/$evidence_path" | awk '{print $1}')" == "$expected_digest" ]] \
    || fail_validation "speaker-release-evidence-digest-mismatch"
done

frozen_threshold="$(jq -r "$fluid_release_evidence_prefix | .threshold" "$speaker_registry_path")"
frozen_threshold_policy="$(jq -r "$fluid_release_evidence_prefix | .thresholdPolicy" "$speaker_registry_path")"
frozen_model_id="$(jq -r "$fluid_release_evidence_prefix | .modelArtifactID" "$speaker_registry_path")"
frozen_model_digest="$(jq -r "$fluid_release_evidence_prefix | .modelTreeSHA256" "$speaker_registry_path")"
evaluated_memory="$(jq -r "$fluid_release_evidence_prefix | .evaluatedUnifiedMemoryBytes" "$speaker_registry_path")"

jq -e \
  --arg thresholdPolicy "$frozen_threshold_policy" \
  --argjson threshold "$frozen_threshold" '
  .schemaVersion == 1 and
  .kind == "speaker-release-evaluation-decision" and
  .phase == "tuning-calibration" and
  .status == "pass" and
  .eligibleForHoldout == true and
  .selectionEligible == false and
  .thresholdPolicy == $thresholdPolicy and
  .threshold == $threshold and
  .networkDeniedByParentSandbox == true and
  .knownWrongCount == 0 and
  .falseMergeCount == 0 and
  ([.gates[].status] | all(. == "pass"))
  ' "$speaker_ami_tuning_decision_path" >/dev/null \
  || fail_validation "speaker-ami-tuning-decision-invalid"

jq -e \
  --arg thresholdPolicy "$frozen_threshold_policy" \
  --argjson threshold "$frozen_threshold" '
  .schemaVersion == 1 and
  .kind == "speaker-release-evaluation-decision" and
  .phase == "release-holdout" and
  .status == "pass" and
  .eligibleForHoldout == false and
  .selectionEligible == true and
  .thresholdPolicy == $thresholdPolicy and
  .threshold == $threshold and
  .networkDeniedByParentSandbox == true and
  .knownWrongCount == 0 and
  .falseMergeCount == 0 and
  .unknownRejectedCount == .unknownQueryCount and
  ([.gates[].status] | all(. == "pass")) and
  ([.metrics[] | select(.name == "speaker-confusion-rate") | .value]
    | length == 1 and .[0] <= 0.05)
  ' "$speaker_ami_release_decision_path" >/dev/null \
  || fail_validation "speaker-ami-release-decision-invalid"

for speaker_benchmark in \
  "$speaker_ami_tuning_benchmark_path" \
  "$speaker_ami_release_benchmark_path"
do
  jq -e \
    --arg modelID "$frozen_model_id" \
    --arg modelDigest "$frozen_model_digest" \
    --argjson memory "$evaluated_memory" '
    .schemaVersion == 1 and
    .kind == "benchmark-result" and
    .task == "speaker" and
    .modelArtifact == {artifactID: $modelID, sha256: $modelDigest} and
    .hardware.architecture == "arm64" and
    .hardware.unifiedMemoryBytes == $memory and
    (.failedSampleUUIDs | length == 0) and
    ([.metrics[].name] | contains([
      "der",
      "jer",
      "speaker-miss-rate",
      "speaker-false-alarm-rate",
      "speaker-confusion-rate",
      "false-merge-count",
      "false-split-count",
      "false-reject-count",
      "realtime-factor",
      "peak-rss"
    ]))
    ' "$speaker_benchmark" >/dev/null \
    || fail_validation "speaker-ami-benchmark-invalid"
done

jq -e '
  .schemaVersion == 1 and
  .kind == "corpus-manifest" and
  .manifestID == "ami-public-speaker-tuning-v1" and
  .version == "1.0.0" and
  .tier == "public" and
  .releaseHoldout == false and
  .containsPrivateContent == false and
  (.samples | length == 6) and
  all(.samples[];
    .consentClass == "public" and
    (.assetReference | startswith("external-corpus://ami-1.6.2/"))
  )
  ' "$speaker_ami_tuning_manifest_path" >/dev/null \
  || fail_validation "speaker-ami-tuning-manifest-invalid"

jq -e '
  .schemaVersion == 1 and
  .kind == "corpus-manifest" and
  .manifestID == "ami-public-speaker-release-holdout-v1" and
  .version == "1.0.0" and
  .tier == "release-holdout" and
  .releaseHoldout == true and
  .containsPrivateContent == false and
  (.samples | length == 12) and
  all(.samples[];
    .consentClass == "public" and
    (.assetReference | startswith("external-corpus://ami-1.6.2/"))
  )
  ' "$speaker_ami_release_manifest_path" >/dev/null \
  || fail_validation "speaker-ami-release-manifest-invalid"

jq -e --arg registryDigest "$speaker_registry_digest" \
  --arg corpusDigest "$speaker_corpus_manifest_digest" '
  .schemaVersion == 1 and
  .kind == "recommended-memory-speaker-smoke-summary" and
  .conclusion == "conditional-recommended-memory-smoke-only" and
  .releaseEligible == false and
  .selectionDecision == "no-default-candidate-selected" and
  .candidateRegistry.path == "config/speaker-candidates.json" and
  .candidateRegistry.sha256 == $registryDigest and
  .scope.deviceClass == "recommended-memory-development-host" and
  .scope.architecture == "arm64" and
  (.scope.unifiedMemoryBytes >= 17179869184) and
  .scope.networkDeniedDuringInference == true and
  .corpus.manifestID == "product-synthetic-speaker-smoke" and
  .corpus.version == "1.0.0" and
  .corpus.manifestPath == "Corpus/product-synthetic/speaker-manifest.json" and
  .corpus.manifestSHA256 == $corpusDigest and
  .corpus.diarizationSampleCount == 9 and
  .corpus.identityEnrollmentCount == 6 and
  .corpus.identityQueryCount == 16 and
  (.corpus.identityManifestSHA256 | test("^[0-9a-f]{64}$")) and
  .protocol.diarizationEvaluationCount == 54 and
  .protocol.identityEmbeddingCount == 66 and
  .protocol.queryDataUsedForThresholdTuning == false and
  .protocol.oracleResultsEligibleForSelection == false and
  ([.candidates[].candidateID] | sort) == ["argmax", "fluid", "sherpa"] and
  all(.candidates[];
    .identity.knownWrongCount == 0 and
    .identity.unknownRejectedCount == .identity.unknownQueryCount and
    .identity.falseMergeCount == 0 and
    .identity.falseSplitCount == 0 and
    (.identity.falseRejectCount == .identity.knownRejectedCount)
  ) and
  (.unmetReleaseCriteria | length > 0)
  ' "$speaker_recommended_smoke_path" >/dev/null \
  || fail_validation "speaker-recommended-memory-summary-invalid"

jq -e '
  .schemaVersion == 1 and
  .kind == "corpus-manifest" and
  .manifestID == "product-synthetic-speaker-smoke" and
  .version == "1.0.0" and
  .tier == "product-synthetic" and
  .releaseHoldout == false and
  .containsPrivateContent == false and
  (.samples | length == 9) and
  all(.samples[];
    .consentClass == "synthetic" and
    (.assetReference | startswith("local-corpus://product-synthetic/speaker-v1/")) and
    (.tags | index("speaker") != null) and
    (.tags | index("local-only") != null)
  )
  ' "$speaker_corpus_manifest_path" >/dev/null \
  || fail_validation "speaker-corpus-manifest-invalid"

speaker_registry_ids="$(jq -c '[.candidates[].candidateID] | sort' "$speaker_registry_path")"
speaker_summary_ids="$(jq -c '[.candidates[].candidateID] | sort' "$speaker_recommended_smoke_path")"
[[ "$speaker_registry_ids" == "$speaker_summary_ids" ]] \
  || fail_validation "speaker-candidate-set-mismatch"

while IFS= read -r candidate_id; do
  expected_runtime_revision="$(jq -r --arg id "$candidate_id" \
    '.candidates[] | select(.candidateID == $id) | .upstreamRuntime.revision' \
    "$speaker_registry_path")"
  expected_artifact_id="$(jq -r --arg id "$candidate_id" \
    '.candidates[] | select(.candidateID == $id) | .modelArtifact.artifactID' \
    "$speaker_registry_path")"
  expected_model_digest="$(jq -r --arg id "$candidate_id" \
    '.candidates[] | select(.candidateID == $id) | .modelArtifact.treeSHA256' \
    "$speaker_registry_path")"
  expected_provider="$(jq -r --arg id "$candidate_id" \
    '.candidates[] | select(.candidateID == $id) | .evidence.executionProvider' \
    "$speaker_registry_path")"
  expected_memory="$(jq -r '.scope.unifiedMemoryBytes' "$speaker_recommended_smoke_path")"

  for matrix_mode in automatic oracle; do
    path_key="${matrix_mode}BenchmarkResultPath"
    digest_key="${matrix_mode}BenchmarkResultSHA256"
    result_path="$(jq -r --arg id "$candidate_id" --arg key "$path_key" \
      '.candidates[] | select(.candidateID == $id) | .evidence[$key]' \
      "$speaker_registry_path")"
    expected_result_digest="$(jq -r --arg id "$candidate_id" --arg key "$digest_key" \
      '.candidates[] | select(.candidateID == $id) | .evidence[$key]' \
      "$speaker_registry_path")"

    [[ "$result_path" != /* \
      && "/$result_path/" != *"/../"* \
      && "/$result_path/" != *"/./"* ]] \
      || fail_validation "unsafe-speaker-result-path"
    [[ -f "$repository_root/$result_path" ]] \
      || fail_validation "speaker-result-missing"
    actual_result_digest="$(shasum -a 256 "$repository_root/$result_path" | awk '{print $1}')"
    [[ "$expected_result_digest" == "$actual_result_digest" ]] \
      || fail_validation "speaker-result-digest-mismatch"

    jq -e \
      --arg candidateID "$candidate_id" \
      --arg matrixMode "$matrix_mode" \
      --arg runtimeRevision "$expected_runtime_revision" \
      --arg artifactID "$expected_artifact_id" \
      --arg modelDigest "$expected_model_digest" \
      --argjson unifiedMemoryBytes "$expected_memory" '
      .kind == "benchmark-result" and
      .task == "speaker" and
      .protocolVersion == 1 and
      (.benchmarkID | contains($candidateID) and contains($matrixMode)) and
      .implementationRevision == $runtimeRevision and
      .modelArtifact.artifactID == $artifactID and
      .modelArtifact.sha256 == $modelDigest and
      .corpus == {
        manifestID: "product-synthetic-speaker-smoke",
        version: "1.0.0",
        split: "smoke"
      } and
      .hardware.architecture == "arm64" and
      .hardware.unifiedMemoryBytes == $unifiedMemoryBytes and
      (.failedSampleUUIDs | length == 0) and
      ([.metrics[].name] | contains([
        "der",
        "jer",
        "false-merge-count",
        "false-split-count",
        "false-reject-count",
        "latency-p50",
        "latency-p95",
        "realtime-factor",
        "peak-rss",
        "backlog-high-watermark"
      ]))
      ' "$repository_root/$result_path" >/dev/null \
      || fail_validation "speaker-result-contract-invalid"

    jq -e \
      --arg id "$candidate_id" \
      --arg mode "$matrix_mode" \
      --arg resultPath "$result_path" \
      --arg resultDigest "$actual_result_digest" \
      --arg runtimeRevision "$expected_runtime_revision" \
      --arg artifactID "$expected_artifact_id" \
      --arg modelDigest "$expected_model_digest" \
      --arg provider "$expected_provider" '
      any(.candidates[];
        .candidateID == $id and
        .runtimeRevision == $runtimeRevision and
        .modelArtifactID == $artifactID and
        .modelTreeSHA256 == $modelDigest and
        .executionProvider == $provider and
        .[$mode].benchmarkResultPath == $resultPath and
        .[$mode].benchmarkResultSHA256 == $resultDigest
      )
      ' "$speaker_recommended_smoke_path" >/dev/null \
      || fail_validation "speaker-summary-reference-mismatch"

    for metric_name in der jer latency-p95 realtime-factor peak-rss; do
      case "$metric_name" in
        latency-p95) summary_key="latencyP95Milliseconds" ;;
        realtime-factor) summary_key="realtimeFactor" ;;
        peak-rss) summary_key="peakResidentBytes" ;;
        *) summary_key="$metric_name" ;;
      esac
      result_metric="$(jq -r --arg name "$metric_name" \
        '.metrics[] | select(.name == $name) | .value' \
        "$repository_root/$result_path")"
      summary_metric="$(jq -r --arg id "$candidate_id" --arg mode "$matrix_mode" --arg key "$summary_key" \
        '.candidates[] | select(.candidateID == $id) | .[$mode][$key]' \
        "$speaker_recommended_smoke_path")"
      [[ "$result_metric" == "$summary_metric" ]] \
        || fail_validation "speaker-summary-metric-mismatch"
    done

    result_false_reject="$(jq -r \
      '.metrics[] | select(.name == "false-reject-count") | .value' \
      "$repository_root/$result_path")"
    summary_false_reject="$(jq -r --arg id "$candidate_id" \
      '.candidates[] | select(.candidateID == $id) | .identity.falseRejectCount' \
      "$speaker_recommended_smoke_path")"
    [[ "$result_false_reject" == "$summary_false_reject" ]] \
      || fail_validation "speaker-identity-metric-mismatch"
  done
done < <(jq -r '.candidates[].candidateID' "$speaker_registry_path")

jq -e '
  .conclusion == "pass" and
  .selectionDecision == "no-default-candidate-selected" and
  (.unmetReleaseCriteria | length > 0) and
  all(.candidates[];
    .digestScope == "contract-fixture-only" and
    .executionMode == "contract-fixture-runtime" and
    .realModelArtifactStatus == "recommended-memory-smoke-complete-release-matrix-pending" and
    (.realModelTreeSHA256 | test("^[0-9a-f]{64}$")) and
    (.recommendedMemoryBenchmarkResult | startswith("artifacts/evidence/SPIKE-ASR-001/")) and
    .releaseEligible == false and
    (.scenarios | length == 10) and
    all(.scenarios[]; .status == "pass")
  )' "$asr_contract_path" >/dev/null \
  || fail_validation "asr-contract-claims-release-readiness"

jq -e '
  .conclusion == "pass" and
  any(.candidates[]; .hardGateEligible == true) and
  any(.candidates[]; .hardGateEligible == false)' "$llm_matrix_path" >/dev/null \
  || fail_validation "llm-hard-gate-invalid"
jq -e '
  .conclusion == "pass" and
  .priorityOrder == ["capture", "journal", "live-asr", "final-asr", "local-text", "speaker"]' \
  "$resource_matrix_path" >/dev/null \
  || fail_validation "resource-priority-invalid"

for release_report in \
  "artifacts/evidence/SPIKE-ASR-001/summary.json" \
  "artifacts/evidence/SPIKE-SPK-001/summary.json"
do
  if [[ ! -f "$repository_root/$release_report" ]] \
    || [[ "$(jq -r '.conclusion // "missing"' "$repository_root/$release_report" 2>/dev/null || print missing)" != "pass" ]]
  then
    missing_reports+=("$release_report")
  fi
done

if (( ${#missing_reports[@]} > 0 )); then
  jq -e '
    .selectionStatus == "alpha-default-selected-from-local-corpus" and
    ([.candidates[] | select(.alphaDefault == true)] | length == 1) and
    all(.candidates[]; .releaseEligible == false)' "$registry_path" >/dev/null \
    || fail_validation "premature-release-selection"
  jq -e '
    .selectionStatus == "fluid-public-holdout-selected-production-candidate-16gb-release-gate-pending" and
    ([.candidates[] | select(.frozenProductionCandidate == true) | .candidateID] == ["fluid"]) and
    all(.candidates[]; .releaseEligible == false)' "$speaker_registry_path" >/dev/null \
    || fail_validation "premature-speaker-default-selection"
fi

write_summary
print "inference evidence integrity passed; selection remains blocked by ${#missing_reports[@]} report(s)"
