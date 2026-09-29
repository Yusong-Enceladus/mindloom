# SPIKE-RES-001 resource policy evidence

`summary.json` is the schema-validated spike decision record. `matrix.json` records all eight deterministic pressure and recovery scenarios, the ordered work directives, observable reason codes, and AudioJournal preservation counters.

Regenerate from the repository root with:

```sh
script/run_resource_policy_probe.sh
```

The committed result is `pass`: all 16 attempted capture chunks were committed and remained readable after reopening the journal, with zero gaps. This probe validates scheduler semantics and recovery. It does not replace the required real-model measurements on the 16 GB minimum device and recommended-memory hardware.
