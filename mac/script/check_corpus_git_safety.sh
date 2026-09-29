#!/bin/zsh

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
scan_root="$repository_root"
include_untracked=0

while (( $# > 0 )); do
  case "$1" in
    --root)
      [[ $# -ge 2 ]] || { print -u2 "error: --root needs a value"; exit 64; }
      scan_root="$2"
      shift 2
      ;;
    --include-untracked)
      include_untracked=1
      shift
      ;;
    *)
      print -u2 "error: unknown argument: $1"
      exit 64
      ;;
  esac
done

git -C "$scan_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  print -u2 "error: corpus Git safety check requires a Git worktree"
  exit 2
}

findings_directory="$(mktemp -d "${TMPDIR:-/tmp}/bestasr-corpus-git.XXXXXX")"
findings_path="$findings_directory/findings.txt"
touch "$findings_path"
trap 'rm -f "$findings_path"; rmdir "$findings_directory" 2>/dev/null || true' EXIT

if (( include_untracked == 1 )); then
  git_arguments=(ls-files --cached --others --exclude-standard)
else
  git_arguments=(ls-files)
fi

while IFS= read -r relative_path; do
  [[ "$relative_path" == Corpus/* ]] || continue
  lowercase_path="${relative_path:l}"

  case "$lowercase_path" in
    *.wav|*.m4a|*.mp3|*.aac|*.flac|*.caf|*.aiff|*.mp4|*.mov|*.mkv|*.webm|*.transcript.txt|*.embedding|*.embedding.json|*.dictionary.json|*.onnx|*.gguf|*.safetensors|*.mlmodelc|*.p12|*.cer|*.mobileprovision)
      print "forbidden-corpus-file:$relative_path" >> "$findings_path"
      continue
      ;;
  esac

  case "$relative_path" in
    Corpus/private-consented/README.md|Corpus/private-consented/manifest.json|Corpus/release-holdout/README.md|Corpus/release-holdout/*manifest.json)
      ;;
    Corpus/private-consented/*|Corpus/release-holdout/*|Corpus/device-lab/captures/*)
      print "forbidden-corpus-payload:$relative_path" >> "$findings_path"
      ;;
  esac
done < <(git -C "$scan_root" "${git_arguments[@]}")

/usr/bin/sort -u "$findings_path" -o "$findings_path"
if [[ -s "$findings_path" ]]; then
  print -u2 "corpus Git safety check failed:"
  /bin/cat "$findings_path" >&2
  exit 1
fi

print "corpus Git tracked-file safety passed"
