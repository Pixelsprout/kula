#!/bin/sh
# Usage: scripts/local.sh on | off
# on: saves the header to .header.url, points pf, linalg, mesh and ui at a
#     rocco-engine checkout and builds its platform for this machine.
#     ROCCO_DIR names the checkout, relative to this directory or absolute.
#     It defaults to ../rocco-engine.
# off: puts the saved header back.
set -eu
cd "$(dirname "$0")/.."

saved=.header.url
rocco=${ROCCO_DIR:-../rocco-engine}

case "${1:-}" in
on)
	if [ -e "$saved" ]; then
		echo "local.sh: $saved exists, so the header is already local. Run scripts/local.sh off first." >&2
		exit 1
	fi
	if [ ! -f "$rocco/platform/main.roc" ]; then
		echo "local.sh: $rocco/platform/main.roc is missing. Set ROCCO_DIR to a rocco-engine checkout." >&2
		exit 1
	fi
	python3 - "$rocco" "$saved" <<'PY'
import re, sys

rocco, saved = sys.argv[1].rstrip("/"), sys.argv[2]
# Bytes keep the line endings, so off gives back the same file on Windows too.
with open("main.roc", "rb") as f:
    text = f.read().decode()
end = text.index("\n") + 1
header, body = text[:end], text[end:]
paths = {
    "pf": f'platform "{rocco}/platform/main.roc"',
    "linalg": f'"{rocco}/packages/linalg/main.roc"',
    "mesh": f'"{rocco}/packages/mesh/main.roc"',
    "ui": f'"{rocco}/packages/ui/main.roc"',
}
local = header
for name, value in paths.items():
    local, count = re.subn(rf'\b{name}: (platform )?"[^"]*"', lambda _: f"{name}: {value}", local)
    if count != 1:
        sys.exit(f"local.sh: the header names {name} {count} times, not once")
with open(saved, "wb") as f:
    f.write(header.encode())
with open("main.roc", "wb") as f:
    f.write((local + body).encode())
PY
	git config core.hooksPath .githooks
	(cd "$rocco" && roc scripts/build.roc -- host && roc scripts/build.roc -- inputs)
	echo "local.sh: main.roc now uses $rocco. Run scripts/local.sh off before you commit."
	;;
off)
	if [ ! -f "$saved" ]; then
		echo "local.sh: $saved is missing, so the header is not local." >&2
		exit 1
	fi
	tail -n +2 main.roc > main.roc.tmp
	cat "$saved" main.roc.tmp > main.roc
	rm main.roc.tmp "$saved"
	echo "local.sh: main.roc uses the bundle URLs again."
	;;
*)
	echo "usage: scripts/local.sh on | off" >&2
	exit 2
	;;
esac
