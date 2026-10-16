#!/bin/sh
# Usage: scripts/check-header.sh [file]
# Fails if the app header names a local path, such as ../ or a ROCCO_DIR
# checkout. Reads main.roc, or stdin for -.
set -eu
cd "$(dirname "$0")/.."

file=${1:-main.roc}
if [ "$file" = - ]; then
	header=$(head -n 1)
else
	header=$(head -n 1 "$file")
fi
case "$header" in
*../* | *main.roc\"*)
	echo "check-header: the main.roc header names a local path. Run scripts/local.sh off." >&2
	exit 1
	;;
esac
