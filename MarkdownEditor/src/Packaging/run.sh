#!/bin/zsh
# Builds a debug MarkdownEditor.app and launches it, optionally with files.
#
#   Packaging/run.sh [file.md …]
set -euo pipefail

APP="$("${0:A:h}/make-app.sh" debug | tail -1)"
# Quit a running copy so the fresh build is the one that opens.
pkill -x MarkdownEditor 2>/dev/null && sleep 0.5 || true
open -n "$APP" --args "$@"
