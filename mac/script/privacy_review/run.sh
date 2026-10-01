#!/bin/zsh
# Privacy review probe for screenshot redaction (review FINDINGS.md F2). Builds this checkout's
# ImageNormalizer + VisionSendCopyRedactor with a small driver (no package build), renders synthetic
# screenshots with invented numbers, redacts them, and exits 1 when an identifier stays legible.
# Build output goes under $BESTASR_BUILD_ROOT (the external build volume), never the system disk.
#   BESTASR_BUILD_VOLUME=/Volumes/<volume> PYTHON=<python with Pillow> script/privacy_review/run.sh
set -eu
here=${0:A:h}
src=$here/../../Packages/BestASRCore/Sources
source $here/../build_storage.sh
out=$BESTASR_BUILD_ROOT/privacy-review-probe
mkdir -p $out/img $out/modcache
sed '/^import BestASRDomain$/d' $src/BestASRIntake/VisionSendCopyRedactor.swift > $out/VisionSendCopyRedactor.swift
sed '/^import BestASRDomain$/d' $src/BestASRIntake/ImageNormalizer.swift > $out/ImageNormalizer.swift
cp $here/redaction_probe.swift $out/main.swift  # top-level code must live in main.swift
xcrun swiftc -O -module-cache-path $out/modcache -o $out/redaction_probe \
  $here/Stubs.swift $src/BestASRDomain/PrivacyMask.swift $out/ImageNormalizer.swift \
  $out/VisionSendCopyRedactor.swift $out/main.swift
${PYTHON:-python3} $here/make_images.py $out/img
$out/redaction_probe $out/img
