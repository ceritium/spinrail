#!/bin/bash
# Runs as root only long enough to fence the network off, then hands over to
# the unprivileged runner user, which has no sudo and so cannot undo it.
set -euo pipefail

/usr/local/sbin/fence-network

token="$RUNNER_TOKEN"
unset RUNNER_TOKEN

cd /home/runner
exec setpriv --reuid runner --regid runner --init-groups --inh-caps=-all \
  env HOME=/home/runner USER=runner RUNNER_TOKEN_ONCE="$token" bash -c '
    set -euo pipefail
    token="$RUNNER_TOKEN_ONCE"; unset RUNNER_TOKEN_ONCE
    ./config.sh --unattended --ephemeral \
      --url "https://github.com/${GITHUB_REPOSITORY:-ceritium/spinrail}" \
      --token "$token" \
      --name "${RUNNER_NAME:-runner}-$(hostname)" \
      --labels spinrail \
      --work _work >/dev/null
    unset token
    exec ./run.sh
  '
