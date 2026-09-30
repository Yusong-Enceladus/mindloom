#!/bin/bash
# Skip the dev-week-v1 run (no time left before the 11:00 PDT stop): stop it as soon as it starts.
cd ~/hack/claude-models/v5
until grep -qE "$1 (START dev-r1|DONE)" progress.log; do sleep 5; done
sleep 3
if grep -q "$1 START dev-r1" progress.log; then
  echo "$(date '+%F %T %Z') $1 SKIP dev-r1 (stopped at start: not enough time before 11:00 PDT)" >> progress.log
  pkill -f "run_eval.py --scenario eval/scenarios/dev-week-v1"
fi
