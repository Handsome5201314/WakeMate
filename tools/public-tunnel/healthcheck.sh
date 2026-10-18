#!/bin/sh
set -eu

exec ssh -S /run/ssh/control -O check \
  -o BatchMode=yes \
  "${WAKEMATE_SSH_USER}@${WAKEMATE_SSH_HOST}" >/dev/null 2>&1
