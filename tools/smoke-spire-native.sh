#!/usr/bin/env bash
# Preserve the issuer fixture's public opt-in command and containment profile.
exec bash "$(dirname -- "${BASH_SOURCE[0]}")/smoke-native-private-server.sh" spire "$@"
