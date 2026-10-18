#!/bin/sh
set -eu

: "${WAKEMATE_SSH_HOST:?required}"
: "${WAKEMATE_SSH_USER:?required}"
umask 077
cp /ssh-source/private_key /run/ssh/private_key
chmod 600 /run/ssh/private_key

exec ssh -N -T -M -S /run/ssh/control \
  -i /run/ssh/private_key \
  -o BatchMode=yes \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile=/ssh-source/known_hosts \
  -o GlobalKnownHostsFile=/dev/null \
  -o UpdateHostKeys=no \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=20 \
  -o ServerAliveCountMax=3 \
  -o ConnectTimeout=15 \
  -o LogLevel=ERROR \
  -R 127.0.0.1:18090:api:8000 \
  "${WAKEMATE_SSH_USER}@${WAKEMATE_SSH_HOST}"
