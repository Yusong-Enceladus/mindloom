# Local evaluation corpus layout

This directory commits only versioned manifests and content-free metadata fixtures.
Raw audio, transcripts, speaker embeddings, dictionaries, participant metadata, and
release-holdout payloads stay outside the repository.

The six required tiers are:

- \`public\`: redistributable or externally referenced public samples.
- \`product-synthetic\`: deterministic, non-human product fixtures.
- \`device-lab\`: tagged playback/capture metadata; local captures are ignored.
- \`private-consented\`: opaque consented sample IDs and hashes only.
- \`adversarial\`: synthetic regression and boundary cases.
- \`release-holdout\`: isolated manifest metadata; payloads are never committed.

\`fixture://\` references identify deterministic, non-private fixtures.
\`local-corpus://\` references resolve through a developer-local corpus store and must
never contain a filesystem path. Manifests never contain transcript text.
\`external-corpus://\` references identify license-reviewed public artifacts by
dataset version and relative alias. The repository records their official source,
byte count, and SHA-256 in a versioned evaluation plan; downloaded payloads remain
outside Git. Corpus attribution is retained in the matching notice file under
\`Legal/\`. The FLEURS tuning manifest contains only the 48 public, real-human
samples; its local benchmark run also includes the separately versioned 16-sample
product-synthetic dangerous-token component declared by the evaluation plan.

A public artifact may be assigned to the \`release-holdout\` tier. That tier is about
evaluation isolation, not privacy or redistribution: its payload root remains separate
and unreadable to tuning even when the underlying corpus is publicly downloadable.

## Runtime split isolation

The tuning payload root and release-holdout payload root are separate, non-nested
directories outside the repository. A tuning run receives only the tuning root.
The benchmark loader resolves symlinks and verifies the authorized root before it
reads a manifest, then verifies the logical `tier` and `releaseHoldout` fields after
decoding. A tuning result cannot be reused as release evidence, and every result
records a canonical configuration hash.
