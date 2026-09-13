#!/usr/bin/env bash
# helper: ./d.sh <args...>   -> forwards to hdc
HDC="/d/DevEco Studio/sdk/default/openharmony/toolchains/hdc"
exec "$HDC" "$@"
