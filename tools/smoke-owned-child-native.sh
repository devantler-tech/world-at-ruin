#!/usr/bin/env bash
# Run only the unpublished diagnostic process/sender fixture with explicit opt-in.
exec bash "$(dirname -- "${BASH_SOURCE[0]}")/smoke-native-private-server.sh" owned-child "$@"
