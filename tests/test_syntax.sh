#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash -n "$ROOT/mirror-manager.sh"
[[ "$(bash "$ROOT/mirror-manager.sh" --version)" == 'HostBaran Mirror Manager v1.0.0' ]]
if bash "$ROOT/mirror-manager.sh" --help | grep -q -- '--dry-run'; then :; else exit 1; fi
echo 'Syntax and CLI tests passed.'
