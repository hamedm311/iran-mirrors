#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MIRROR_MANAGER_LIB_ONLY=1
# shellcheck disable=SC1090
source "$ROOT/mirror-manager.sh"
BACKUP_ENABLED=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

UBUNTU_MIRROR='https://ir.archive.ubuntu.com'
ALMALINUX_MIRROR='https://mirror.hostbaran.com/almalinux'
EPEL_MIRROR='https://mirror.hostbaran.com/epel'
MARIADB_MIRROR='https://mirror.hostbaran.com/mariadb'

cat > "$TMP/sources.list" <<'EOF'
deb http://archive.ubuntu.com/ubuntu noble main universe
deb https://download.docker.com/linux/ubuntu noble stable
# deb http://security.ubuntu.com/ubuntu noble-security main
EOF
transform_ubuntu_file "$TMP/sources.list"
grep -q 'https://ir.archive.ubuntu.com/ubuntu noble' "$TMP/sources.list"
grep -q 'https://download.docker.com/linux/ubuntu' "$TMP/sources.list"
grep -q '# deb http://security.ubuntu.com' "$TMP/sources.list"

cat > "$TMP/almalinux.repo" <<'EOF'
[baseos]
name=AlmaLinux $releasever - BaseOS
mirrorlist=https://mirrors.almalinux.org/mirrorlist/$releasever/baseos
enabled=1
gpgcheck=1

[disabled]
name=AlmaLinux disabled
mirrorlist=https://mirrors.almalinux.org/mirrorlist/$releasever/baseos
enabled=0

[custom]
name=Internal repository
baseurl=https://repo.internal.example/os/
enabled=1
EOF
transform_alma_file "$TMP/almalinux.repo"
grep -q '^# mirrorlist=' "$TMP/almalinux.repo"
grep -q '^baseurl=https://mirror.hostbaran.com/almalinux/\$releasever/BaseOS/\$basearch/os/' "$TMP/almalinux.repo"
grep -q 'enabled=0' "$TMP/almalinux.repo"
grep -q 'https://repo.internal.example/os/' "$TMP/almalinux.repo"

echo 'All transformation tests passed.'
