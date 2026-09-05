#!/usr/bin/env bash

if [ -z "${_DOCKER_SG_REEXEC:-}" ] && ! docker info >/dev/null 2>&1 \
   && id -nG "$(id -un)" | tr ' ' '\n' | grep -qx docker; then
  export _DOCKER_SG_REEXEC=1
  exec sg docker -c "$(printf '%q ' "$0" "$@")"
fi
