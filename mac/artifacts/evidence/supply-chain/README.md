# Supply-chain evidence

- `sbom.cdx.json` is the CycloneDX 1.6 inventory generated from the exact dependency and model registries. The current foundation lists three evaluated development/probe dependencies and zero release-approved models.
- `release-manifest.json` records every file in the ad-hoc signed Release App by package-relative path, byte count, kind, and SHA-256.
- `release-package-validation-summary.json` proves the frozen manifest exactly matches the seven-file App/XPC bundle and contains no unregistered binary or model.
- `artifact-validation-summary.json` and `model-activation-summary.json` cover registry completeness and ModelManager last-known-good behavior.

`script/generate_supply_chain.sh` regenerates the SBOM and manifest from a Release build. `script/validate_release_package.sh` validates without changing the frozen inventory. Planted tests add an unregistered Mach-O, add an unregistered `.onnx`, and mutate a registered resource; every case must fail.

This evidence is not Developer ID or notarization approval. Those credentials and service results remain a separate release gate.
