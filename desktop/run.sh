#!/bin/sh
# Starts Sticky Notes (VS Code terminals set ELECTRON_RUN_AS_NODE, which would make Electron run as plain Node)
cd "$(dirname "$0")" && exec env -u ELECTRON_RUN_AS_NODE ./node_modules/.bin/electron . "$@"
