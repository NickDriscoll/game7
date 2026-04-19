#!/usr/bin/env bash

set -euxo pipefail

ODIN_ROOT=$(odin root)
ODIN_JS="$ODIN_ROOT/core/sys/wasm/js/odin.js"

odin build . -target:js_wasm32 -out:web/module.wasm -vet -strict-style -disallow-do -vet-tabs -vet-cast $@

cp $ODIN_JS web/odin.js
