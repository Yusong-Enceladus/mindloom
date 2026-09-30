#!/bin/bash
# Stop the gpt-oss holdout run once its third checkpoint snapshot exists, or at 09:50 PDT at the latest.
cd ~/hack/claude-models/v5
S=out/gpt-oss-120b/h2-skills-r1/snapshots/cp3_wed_night.json
while [ ! -f $S ] && [ $(date +%s) -lt 1790700615 ]; do sleep 10; done
sleep 5
echo "$(date '+%F %T %Z') gpt-oss-120b TIMECAP kill h2-r1 (after cp3 or 09:50 PDT)" >> progress.log
pkill -f budget_wrap.py
