#!/bin/bash
# Copy the organizer code and skills from this checkout to the Spark (run on the Mac).
# Only code is copied; the Spark keeps its database in ~/hack/organizer-data (never in the repo).
# Usage: spark/deploy.sh <spark-ssh-host>   (there is no default host)
set -euo pipefail
HOST=${1:?usage: spark/deploy.sh <spark-ssh-host>}
REPO=$(cd "$(dirname "$0")/.." && pwd)
ssh "$HOST" 'mkdir -p ~/hack/organizer'
rsync -a --delete --exclude '__pycache__' --exclude '.pytest_cache' --exclude '*.db*' \
  "$REPO/spark" "$REPO/skills" "$HOST:hack/organizer/"
echo "deployed to $HOST:~/hack/organizer; restart with: ssh $HOST ~/hack/organizer/spark/ctl.sh restart"
