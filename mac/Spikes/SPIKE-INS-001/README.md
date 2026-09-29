# SPIKE-INS-001: safe Accessibility text insertion

The deterministic contract probe covers selection replacement, non-editable and
secure targets, permission denial, focus/selection races, known-unsupported AX
replacement fallback, unknown write-effect rejection, and clipboard restoration races. Reports contain
only structural status and counters; replacement text and target metadata are not
persisted.

Run the policy layer with:

```sh
script/run_text_insertion_policy_probe.sh
```

`contract-summary.json` is intentionally `conditional`: an unlocked-device run
with Accessibility permission was required before the policy could be treated as
a real AX probe.

Run the signed synthetic AppKit fixture with:

```sh
script/run_text_insertion_live_probe.sh
```

`live-summary.json` records seven live Accessibility scenarios: direct selection
replacement, non-editable and secure rejection, injected denial before any
write, focus and selection races, and a standard Command-V fallback that
restores the prior multi-item/type clipboard only while it still owns the
pasteboard. The final unlocked-device run passed all seven scenarios with zero
wrong-target writes and persists no target text, clipboard data, or bundle ID.
This completes task 5.1.

Run one explicitly blank or fixed synthetic external target at a time with:

```sh
script/run_text_insertion_compatibility_probe.sh \
  --target-id textedit \
  --target-classes apple-editor,rich-text \
  --expected-bundle-id com.apple.TextEdit
```

The runner refuses non-empty content it cannot prove is its own fixed synthetic
seed, then executes 20 standard trials and 5 forced clipboard-fallback trials.
It records only version, role, counters, latency percentiles, and structural
failure categories; it never persists target text, window titles, or clipboard
content.

The current matrix passes TextEdit 1.20, Chrome 150, Word 16.104, Outlook 16.104
empty-draft subject, and VS Code 1.127.0 in its temporarily enabled screen-reader
mode. Every target passed 25/25 trials with zero wrong-target writes, clipboard
restore failures, or unexpected side effects. The Outlook body was not used
because an existing signature made it non-empty; Claude was refused because its
AX value was non-empty; logged-out WeChat was not altered. VS Code's temporary
screen-reader setting was restored after the run.

Task 5.2 remains incomplete and the aggregate conclusion remains `conditional`:
Terminal exposes prior prompt/history content rather than a safely blank target,
so the terminal class still needs a controlled device-lab fixture before the
support matrix can be selected.
