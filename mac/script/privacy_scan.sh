#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
scan_root="$repository_root"
summary_path="$repository_root/artifacts/evidence/privacy/privacy-scan-summary.json"
allowlist_path="$repository_root/config/privacy-scan-allowlist.txt"

while (( $# > 0 )); do
  case "$1" in
    --root)
      scan_root="$(cd "$2" && pwd)"
      shift 2
      ;;
    --summary)
      summary_path="$2"
      shift 2
      ;;
    --allowlist)
      allowlist_path="$2"
      shift 2
      ;;
    *)
      print -u2 "error: unknown argument: $1"
      exit 64
      ;;
  esac
done

command -v rg >/dev/null 2>&1 || { print -u2 "error: rg is required"; exit 2; }
command -v jq >/dev/null 2>&1 || { print -u2 "error: jq is required"; exit 2; }

finding_directory="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-privacy-scan.XXXXXX")"
findings_path="$finding_directory/findings.txt"
touch "$findings_path"
trap 'rm -f "$findings_path"; rmdir "$finding_directory" 2>/dev/null || true' EXIT

git_root=""
scan_git_prefix=""
candidate_git_root="$(git -C "$scan_root" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -n "$candidate_git_root" \
  && ( "$scan_root" == "$candidate_git_root" \
    || "$scan_root" == "$candidate_git_root"/* ) ]]
then
  git_root="$candidate_git_root"
  if [[ "$scan_root" != "$git_root" ]]; then
    scan_git_prefix="${scan_root#$git_root/}/"
  fi
fi

is_allowed() {
  local relative_path="$1"
  [[ -f "$allowlist_path" ]] && /usr/bin/grep -Fq "$relative_path|" "$allowlist_path"
}

is_git_ignored() {
  local relative_path="$1"
  [[ -n "$git_root" ]] || return 1
  git -C "$git_root" check-ignore -q -- "${scan_git_prefix}${relative_path}" \
    2>/dev/null
}

is_registered_model() {
  local relative_path="$1"
  local registry_path="$repository_root/config/model-artifacts.json"
  [[ -f "$registry_path" ]] || return 1
  jq -e --arg path "$relative_path" \
    'any(.models[]?.files[]?; .relativePath == $path)' \
    "$registry_path" >/dev/null 2>&1
}

while IFS= read -r absolute_path; do
  [[ -n "$absolute_path" ]] || continue
  relative_path="${absolute_path#$scan_root/}"
  if is_git_ignored "$relative_path"; then
    continue
  fi
  case "${relative_path:l}" in
    *.onnx|*.gguf|*.safetensors|*.mlmodelc)
      if is_registered_model "$relative_path"; then
        continue
      fi
      ;;
  esac
  if ! is_allowed "$relative_path"; then
    print "forbidden-file:$relative_path" >> "$findings_path"
  fi
done < <(
  find "$scan_root" -type f \
    -not -path '*/.git/*' \
    \( \
      -path '*/Corpus/private/*' -o \
      -path '*/Models/*' -o \
      -path '*/ModelCache/*' -o \
      -path '*/RuntimeData/*' -o \
      -path '*/diagnostics/*' -o \
      -iname '*.transcript.txt' -o -iname '*.embedding' -o -iname '*.embedding.json' -o \
      -iname '*.dictionary.json' -o \
      -iname '*.wav' -o -iname '*.m4a' -o -iname '*.mp3' -o -iname '*.aac' -o \
      -iname '*.flac' -o -iname '*.mp4' -o -iname '*.mov' -o -iname '*.mkv' -o \
      -iname '*.webm' -o -iname '*.onnx' -o -iname '*.gguf' -o -iname '*.safetensors' -o \
      -iname '*.mlmodelc' -o -iname '*.p12' -o -iname '*.cer' -o \
      -iname '*.mobileprovision' -o -iname '*.provisionprofile' \
    \) -print
)

content_pattern='-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|BESTASR_PLANTED_SECRET|/(Users|home)/[^/[:space:]]+/(Desktop|Documents|Downloads|Library|Movies|Music|Pictures)/|AKIA[0-9A-Z]{16}|hf_[A-Za-z0-9]{30,}|sk-[A-Za-z0-9_-]{32,}'
while IFS= read -r matched_path; do
  [[ -n "$matched_path" ]] || continue
  relative_path="${matched_path#./}"
  if is_git_ignored "$relative_path"; then
    continue
  fi
  if ! is_allowed "$relative_path"; then
    print "content-signature:$relative_path" >> "$findings_path"
  fi
done < <(
  cd "$scan_root"
  rg --hidden --files-with-matches --glob '!.git' --glob '!.git/**' -- "$content_pattern" . 2>/dev/null || true
)

/usr/bin/sort -u "$findings_path" -o "$findings_path"
finding_count="$(/usr/bin/awk 'NF { count += 1 } END { print count + 0 }' "$findings_path")"
scan_status="pass"
if (( finding_count > 0 )); then
  scan_status="fail"
fi

summary_directory="$(dirname "$summary_path")"
mkdir -p "$summary_directory"
summary_temp="$finding_directory/summary.json"
jq -n \
  --arg status "$scan_status" \
  --arg gitVisibilityScope "$([[ -n "$git_root" ]] && print 'tracked-and-unignored' || print 'all-files')" \
  --argjson findingCount "$finding_count" \
  --rawfile findings "$findings_path" \
  '{
    schemaVersion: 1,
    status: $status,
    gitVisibilityScope: $gitVisibilityScope,
    findingCount: $findingCount,
    findings: ($findings | split("\n") | map(select(length > 0)))
  }' > "$summary_temp"
mv "$summary_temp" "$summary_path"

if [[ "$scan_status" != "pass" ]]; then
  print -u2 "privacy scan failed with $finding_count finding(s); see $summary_path"
  exit 1
fi

print "privacy scan passed"
