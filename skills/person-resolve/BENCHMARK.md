# person-resolve benchmark

All data is synthetic. The three large scenarios are the 1,500–1,600-item weeks of `eval/scale/README.md`
(lab and pm are dev, startup is held out and was never used to tune anything here). Model: Qwen3.6-35B-A3B
NVFP4 on the node's own vLLM, thinking off, temperature 0.

The current code is **1.2.1**: 1.2.0 plus the placeholder line (「占位符（如〔手机号·a1b2c3〕）是被遮住的号码，原样保留，不要猜、不要改写。」) and the material-is-data line; it was not re-evaluated, so every number below is 1.2.0. Since the privacy integration (2026-09-30) the pass runs only while the store is unlocked, its calls are bound to the unlock session and record the items whose lines they show (deleting one clears the call), and every output has broken placeholders repaired; none of this changes a verdict.

## What is measured

The people pass (`spark/organizer/people_pass.py`) is applied **post hoc through the runtime path**: a new
organizer instance with this code is started on a copy of each scenario's final organized state (after
event consolidation), nothing is sent to it, and it runs the pass on its own when idle, like any older store
after an upgrade (`ORGANIZER_CONSOLIDATE=0` in these copies so only the people pass acts). Its `/v1/state`
and item→person links are then scored with the same scorer and ID ledger as the 2026-09-29 scale report.

| Metric | Meaning |
|---|---|
| person link (event level) | the scale report's "人物关联（退化口径）": for each predicted event matched to a real matter, the share of that matter's people who appear among the event's people under a name the scenario lists for them. Recall only. |
| item level: recall / precision | gold (item, person) pairs whose item carries the predicted person the gold person maps to (one-to-one by item overlap); precision = linked pairs whose person maps to a gold person of that item. |
| people shown | live person records linked to at least one live event (the owner excluded); the scenarios have 35 / 41 / 42 real non-owner people |
| no scenario person | of those, records whose name (or its Chinese / Latin part, or its base without a remark) is no name or alias of any scenario person: labels, code keys, phrases, and people the scenario does not list |
| records per person | people-shown records per real person who has at least one |

## Results (code 8138c7f, person-resolve 1.2.0)

| Scenario | person link (event level) | item level recall (precision) | people shown | no scenario person | records per person | real people found |
|---|---|---|---|---|---|---|
| lab (dev) | 0.301 → **0.447** | 0.168 (0.971) → **0.655** (0.969) | 157 → **65** | 85 → **22** | 2.40 → **1.34** | 30 → 32 of 35 |
| pm (dev) | 0.290 → **0.477** | 0.189 (0.803) → **0.689** (0.305¹) | 216 → **102** | 77 → **9** | 3.86 → **2.58** | 36 → 36 of 41 |
| startup (**held out**) | 0.269 → **0.417** | 0.134 (0.954) → **0.647** (0.997) | 110 → **52** | 53 → **7** | 1.39 → **1.07** | 41 → 42 of 42 |
| lab demo state (lab-v3) | 0.304 → **0.458** | 0.244 (1.000) → **0.654** (0.963) | 90 → **65** | 43 → **22** | 1.57 → **1.34** | 30 → 32 of 35 |

"Before" is each store after the first-round event consolidation, so its event-level number is a little above
the 0.23–0.26 of the 2026-09-29 scale report (events match the real matters better).

¹ pm's gold lists only the people each item was planned around; the generator's text names more. Of the
5,812 pm links after the pass, 1,942 are in the gold lists and 3,747 more are a scenario person named in the
item's own text (by full name or alias, or a speaker line): 97.9% of the links are grounded that way.
With person-resolve 1.1.0 the model had taken a product's nickname for a person and mention linking gave
it 557 items (89.0% grounded); 1.2.0 says product, project and assistant names are not people.

- Most of the gain is mentions: before, people were linked only to the items where they speak, so a dictation
  or an e-mail that names four colleagues linked none of them. Of the event-level pairs the old state missed
  on lab, 343 of 408 were a person the store knew but had not linked to that matter; none were name variants (4 of 445 on pm).
- The speaker rules re-applied to the stored items turned 84 / 48 / 40 label "people" (lab / pm / startup)
  into `not_person` (document fields, English field words, code keys, phrases, exported-chat lines that
  were not read before are now read). The model then judged 78 / 155 / 65 records and marked 2 / 26 / 11 more
  as not a person and 4 / 7 / 1 as roles.
- Merges: 14 / 46 / 4 (bilingual and Latin forms by rule; nicknames and pinyin forms by the model plus the
  guard). The guard refused 7 / 8 / 0 merges the model proposed: short forms that fit two people of one
  family name, two short forms, two people who speak in one item.
- Cost: 65–155 person-resolve calls per 1,500–1,600-item store (0.17–0.41 M input tokens, 3–7 k output),
  1–2 minutes of wall time on a node also running a full organize; organizing those items took 74–77 M.
- People per event grow with mentions (lab demo state: people who turn up in two or more matters, per event,
  4.6 → 7.7 on average; events with 15 or more 2 → 11). `/v1/state` lists an event's people most involved
  first; a client should cap its chip row.

## Held-out full run (startup, organized from scratch)

The same scenario organized end to end twice with the same driver (`eval/run_eval.py --stream --workers 4`, replay
clock, 1,600 items in 6 checkpoints): before this round (8ecc90f, no people pass) and with it (abd9cf0: people pass,
person-resolve 1.1.0, item-split 1.3.0). One run each.

| | before | with the people pass |
|---|---|---|
| person link (event level) | 0.280 | **0.481** |
| item level recall (precision) | 0.135 (0.866) | **0.735** (**0.998**) |
| people shown / no scenario person / records per person | 111 / 54 / 1.39 | **52** / **7** / **1.07** |
| person-resolve calls (input tokens) | — | 68 (0.17 M) of 54.6 M for the whole run |

## Skill evals

`eval/run_skill_evals.py --skills person-resolve --n 3` (invented cases × 3):

| SKILL.md | cases | all 3 runs pass | pass rate |
|---|---|---|---|
| 1.0.0 | 13 | 12 | 0.923 — pr-010 0/3: a name that is also an ordinary word judged "not common" from the name alone |
| 1.1.0 (sees `elsewhere`: other lines that contain the name) | 14 | 14 | 1.000 |
| **1.2.0** (product / project / assistant names are not people) | 15 | **15** | **1.000** |

## Known limits

- Only names the store already knows as people are searched for. Someone who never speaks and is only ever
  named is not found, and nicknames are searched only once the pass has joined them to one person.
- A record is judged once (again only after a rename): a verdict from an older SKILL.md stays until then.
- A family name plus a title, when two known people share the family name, stays a separate record; the
  existing same_person question is asked only for voice people.
- The scenarios have no voice persons; the voice-person path (a question instead of a merge) is covered by
  unit tests only.
