#!/bin/bash
# spark-G: wait for the Nemotron-3-Super organizer eval to finish, run its decode-speed probe, stop it, then the OCR batch.
N=~/hack/claude-models/nemotron3-super; V=~/hack/claude-models/v2
until grep -q ALLDONE $N/progress.txt; do sleep 30; done
cd $N && timeout 600 ~/hack/vllm-venv/bin/python speed.py > $N/logs/speed.json 2> $N/logs/speed.err
pkill -f "vllm serve $N/weights"; sleep 30; pkill -9 -f "vllm serve $N/weights"; sleep 15
echo "$(date '+%F %T %Z') nemotron stopped" >> $V/progress.log
cd $V && exec bash vbatch.sh paddleocr-vl-1.6 glm-ocr deepseek-ocr-2
