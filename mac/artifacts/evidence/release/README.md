# Release smoke evidence

`release-smoke-summary.json` records the local Release/DMG gate without storing certificate names, account identifiers, or credentials.

The current run proves:

- arm64 App and embedded XPC with macOS 14.2 minimum deployment;
- Hardened Runtime and valid nested ad-hoc signatures;
- no injected `get-task-allow`; the App carries only audio-input entitlement;
- a checksummed, structurally valid UDZO DMG.

The result is intentionally `blocked`, not release-ready: this machine has zero Developer ID Application identities and no configured notarytool Keychain profile. Consequently Developer ID, Apple notarization, ticket stapling, and Gatekeeper acceptance remain blocked.

The script performs those external steps only when `BESTASR_RELEASE_SIGNING_ENABLED=1` is deliberately set alongside `BESTASR_DEVELOPER_IDENTITY` and `BESTASR_NOTARY_KEYCHAIN_PROFILE`. Evidence never includes their values.
