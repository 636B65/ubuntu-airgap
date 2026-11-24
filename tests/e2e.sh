#!/usr/bin/env bash
# End-to-end test: build a small *partial* mirror online, then upgrade a
# desktop-like Ubuntu container that has NO network access from it.
#
#   tests/e2e.sh                 # amd64
#   AMD64V3=1 tests/e2e.sh       # amd64 + amd64v3 variant
#   ENGINE=podman tests/e2e.sh   # download with Podman (the client test uses Docker)
#
# The mirror contains all real (signed) index files, but only the .deb files the
# test needs (via --package-filter), so it stays a few hundred MB.
#
# Exercised: Ubuntu archive, a Launchpad PPA (--ppa), a vendor "repo setup"
# .deb built here (--repo-deb, deb822 sources + key + apt pinning),
# by-hash, offline "install", --install-setup-debs, serve and restore.
# shellcheck disable=SC2016  # single-quoted scripts run inside containers
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AMD64V3="${AMD64V3:-0}"
ENGINE="${ENGINE:-auto}"
IMAGE="${IMAGE:-ubuntu:26.04}"
WORK="${WORK:-$(mktemp -d)}"
CLIENT_IMG="ubuntu-airgap-e2e-client:latest"
PPA="git-core/ppa"
PPA_PKG="git-man"
EXTRA_PKG="docker-compose-plugin"

if docker info >/dev/null 2>&1; then DOCKER=(docker); else DOCKER=(sudo docker); fi
step() { printf '\n\033[1;34m### %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }

step "Work dir: $WORK"
mkdir -p "$WORK"

step "Build desktop-like client image (python3, appstream, command-not-found)"
"${DOCKER[@]}" build -q -t "$CLIENT_IMG" - <<EOF
FROM $IMAGE
RUN apt-get update \\
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \\
      python3 appstream command-not-found \\
 && rm -rf /var/lib/apt/lists/* \\
 && rm -f /etc/apt/apt.conf.d/docker-no-languages
EOF

step "Find packages the client can upgrade (online)"
mapfile -t UPG < <("${DOCKER[@]}" run --rm "$CLIENT_IMG" bash -c \
  'apt-get update -qq >/dev/null 2>&1; apt-get -s -o APT::Get::Always-Include-Phased-Updates=true full-upgrade 2>/dev/null | awk "/^Inst /{print \$2}" | sed "s/:.*//"')
echo "upgradable: ${UPG[*]:-(none)}"

step "Build a vendor-style repo setup .deb (deb822 sources, key, pinning)"
"${DOCKER[@]}" run --rm -e DEBIAN_FRONTEND=noninteractive -v "$WORK:/out" "$IMAGE" bash -euc '
  apt-get update -qq >/dev/null && apt-get install -y -qq curl gnupg ca-certificates >/dev/null
  d=/tmp/pkg; mkdir -p $d/DEBIAN $d/etc/apt/sources.list.d $d/etc/apt/preferences.d $d/usr/share/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o $d/usr/share/keyrings/e2e-vendor.gpg
  cat >$d/etc/apt/sources.list.d/e2e-vendor.sources <<EOT
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: resolute
Components: stable
Architectures: amd64
Signed-By: /usr/share/keyrings/e2e-vendor.gpg
EOT
  printf "Package: *\nPin: release o=Docker\nPin-Priority: 600\n" >$d/etc/apt/preferences.d/e2e-vendor-pin
  printf "Package: e2e-repo-setup\nVersion: 1.0\nArchitecture: all\nMaintainer: e2e <e2e@example.com>\nDescription: e2e test repo setup\n" >$d/DEBIAN/control
  dpkg-deb --root-owner-group --build $d /out/e2e-repo-setup_1.0_all.deb >/dev/null
  chown "'"$(id -u):$(id -g)"'" /out/e2e-repo-setup_1.0_all.deb'

# join package names into a regex alternation, escaping . and +
re_join() { local IFS='|' s; s="$*"; s="${s//./\\.}"; s="${s//+/\\+}"; printf '%s' "$s"; }
FILTER="/($(re_join "${UPG[@]}" hello "$PPA_PKG" "$EXTRA_PKG"))_"
if [[ "$AMD64V3" == 1 ]]; then
  # A v3-capable client switches its installed packages to their amd64v3 builds
  # (same version), so the mirror must contain those builds - like a full mirror.
  mapfile -t INST < <("${DOCKER[@]}" run --rm "$CLIENT_IMG" dpkg-query -W -f '${Package}\n')
  FILTER="$FILTER|/($(re_join "${INST[@]}"))_[^/]*_amd64v3\.deb\$"
fi
echo "package filter: $FILTER"

step "Download (online)"
v3=(); [[ "$AMD64V3" == 1 ]] && v3=(--amd64v3)
"$root/ubuntu-airgap.sh" download -d "$WORK/mirror" --engine "$ENGINE" --components main "${v3[@]}" \
  --package-filter "$FILTER" --ppa "$PPA" --repo-deb "$WORK/e2e-repo-setup_1.0_all.deb" \
  >"$WORK/download.log" 2>&1 || { tail -50 "$WORK/download.log"; fail "download failed"; }
grep -E '^==>|Files to download' "$WORK/download.log"

step "Check mirror layout"
M="$WORK/mirror"
for f in airgap-mirror.conf ubuntu-airgap.sh keys/ubuntu-archive-keyring.gpg \
         prefs/e2e-repo-setup-e2e-vendor-pin setup-debs/e2e-repo-setup_1.0_all.deb; do
  [[ -e "$M/$f" ]] || fail "missing $f"
done
# every suite must be signed: InRelease, or Release + Release.gpg (debmirror
# needs only one of the two, and apt accepts either)
for s in resolute resolute-updates resolute-security; do
  d="$M/ubuntu/dists/$s"
  [[ -f "$d/Release" ]] || fail "missing $d/Release"
  [[ -f "$d/InRelease" || -f "$d/Release.gpg" ]] || fail "no signature for $s"
done
grep -q '^repo|ppa-git-core-ppa|repos/ppa-git-core-ppa|resolute|main|' "$M/airgap-mirror.conf" || fail "PPA not in manifest"
grep -q '^repo|e2e-repo-setup-1|repos/e2e-repo-setup-1|resolute|stable|' "$M/airgap-mirror.conf" || fail "setup-deb repo not in manifest"
[[ -n "$(find "$M/ubuntu/dists" -path '*by-hash/SHA256/*' -print -quit)" ]] || fail "no by-hash entries"
if [[ "$AMD64V3" == 1 ]]; then
  grep -q '^arches|amd64,amd64v3' "$M/airgap-mirror.conf" || fail "amd64v3 not in manifest"
  [[ -d "$M/ubuntu/dists/resolute/main/binary-amd64v3" ]] || fail "no binary-amd64v3 indexes"
fi
echo "layout OK"

step "Offline client: install, upgrade, extra repos, restore (--network none)"
"${DOCKER[@]}" run --rm -i --network none -e AMD64V3="$AMD64V3" -e PPA_PKG="$PPA_PKG" -e EXTRA_PKG="$EXTRA_PKG" \
  -v "$M:/media/usb/mirror:ro" "$CLIENT_IMG" bash -s <<'EOS' | tee "$WORK/client.log"
set -Eeuo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
S=/media/usb/mirror/ubuntu-airgap.sh
LOG=/var/log/ubuntu-airgap-http.log

$S install -y --install-setup-debs | tee /tmp/install.log
if [[ "$AMD64V3" == 1 ]] && grep -qw avx2 /proc/cpuinfo; then
  grep -q "switched to their optimised amd64v3 build" /tmp/install.log || fail "no amd64v3 variant switch"
  [[ "$(dpkg-query -W -f='${Architecture-Variant}' bash)" == amd64v3 ]] || fail "bash not switched to amd64v3"
fi

echo "--- no 404s"
missing="$($S _missing -m /media/usb/mirror <"$LOG")"
[[ -z "$missing" ]] || { echo "$missing"; fail "mirror returned 404"; }

echo "--- nothing left to upgrade"
$S serve >/tmp/serve.log 2>&1 &
for _ in $(seq 50); do (exec 3<>/dev/tcp/127.0.0.1/8080) 2>/dev/null && break; sleep 0.2; done
apt-get update -qq
n="$(apt-get -s full-upgrade | grep -c '^Inst ' || true)"
[[ "$n" -eq 0 ]] || { apt-get -s full-upgrade | grep '^Inst '; fail "$n packages still upgradable"; }

echo "--- only the offline sources are active"
[[ "$(ls /etc/apt/sources.list.d)" == "ubuntu-airgap.sources" ]] || { ls -l /etc/apt/sources.list.d; fail "unexpected sources"; }
ls /var/backups/ubuntu-airgap/*/sources.list.d/e2e-vendor.sources >/dev/null || fail "setup-deb sources were not disabled"

echo "--- install from Ubuntu, PPA and vendor repo offline"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends hello "$PPA_PKG" "$EXTRA_PKG" >/dev/null
# (capture first: "cmd | grep -q" can fail with SIGPIPE under pipefail)
out="$(hello)"; [[ "$out" == *"Hello, world"* ]] || fail "hello does not run"
pol="$(apt-cache policy "$PPA_PKG")"
[[ "$(grep -A1 '\*\*\*' <<<"$pol")" == *ppa-git-core-ppa* ]] || { echo "$pol"; fail "$PPA_PKG not from PPA"; }
pol="$(apt-cache policy "$EXTRA_PKG")"
grep -q ' 600 http' <<<"$pol" || { echo "$pol"; fail "vendor pinning (600) not applied"; }

if [[ "$AMD64V3" == 1 ]]; then
  echo "--- amd64v3 variant"
  if grep -qw avx2 /proc/cpuinfo && grep -qw bmi2 /proc/cpuinfo && grep -qw fma /proc/cpuinfo; then
    compgen -G '/var/lib/apt/lists/*binary-amd64v3_Packages*' >/dev/null || fail "amd64v3 indexes not used"
    if ls /media/usb/mirror/ubuntu/pool/main/h/hello/*_amd64v3.deb >/dev/null 2>&1; then
      [[ "$(dpkg-query -W -f='${Architecture-Variant}' hello)" == amd64v3 ]] || fail "hello not installed as amd64v3"
    fi
    echo "amd64v3 OK"
  else
    echo "CPU lacks x86-64-v3; skipping variant assertions"
  fi
fi

echo "--- second install run (idempotent, setup .deb already installed)"
kill %1 2>/dev/null || true; sleep 0.5
$S install -y --install-setup-debs | tee /tmp/install2.log
grep -q "already installed; skipping" /tmp/install2.log || fail "setup .deb was reinstalled"
[[ -z "$($S _missing -m /media/usb/mirror <"$LOG")" ]] || fail "404 on second run"
$S serve >/tmp/serve.log 2>&1 &
for _ in $(seq 50); do (exec 3<>/dev/tcp/127.0.0.1/8080) 2>/dev/null && break; sleep 0.2; done

echo "--- restore"
kill %1 2>/dev/null || true
$S restore
[[ -f /etc/apt/sources.list.d/ubuntu.sources ]] || fail "ubuntu.sources not restored"
[[ ! -e /etc/apt/sources.list.d/ubuntu-airgap.sources ]] || fail "offline sources still present"
ls /etc/apt/preferences.d/ubuntu-airgap-* >/dev/null 2>&1 && fail "pinning not removed"
echo "CLIENT OK"
EOS
# guard against the client script silently not running at all
grep -qx "CLIENT OK" "$WORK/client.log" || fail "offline client test did not complete"

step "Multiarch: client with i386 enabled and libc6:i386 installed (mirror is amd64 only)"
"${DOCKER[@]}" build -q -t "$CLIENT_IMG-i386" - <<EOF
FROM $CLIENT_IMG
# Put libc6 (amd64 AND i386) at the 26.04 release version, so the mirror has a
# newer amd64 libc6 whose i386 twin (Multi-Arch: same) is not in the mirror.
RUN dpkg --add-architecture i386 && apt-get update \\
 && V="\$(apt-cache madison libc6 | grep ' resolute/main ' | head -1 | awk -F'|' '{print \$2}' | tr -d ' ')" \\
 && echo "libc6 release version: \$V" && test -n "\$V" \\
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades --no-install-recommends \\
      libc6=\$V libc-bin=\$V libc-gconv-modules-extra=\$V libc6:i386=\$V libc-gconv-modules-extra:i386=\$V \\
 && rm -rf /var/lib/apt/lists/*
EOF
"${DOCKER[@]}" run --rm -i --network none \
  -v "$M:/media/usb/mirror:ro" "$CLIENT_IMG-i386" bash -s <<'EOS' | tee "$WORK/client-i386.log"
set -Eeuo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
S=/media/usb/mirror/ubuntu-airgap.sh
LOG=/var/log/ubuntu-airgap-http.log
count_i386() { dpkg-query -W -f='${binary:Package}\n' | grep -c ':i386$' || true; }
i386_before="$(count_i386)"

echo "--- install -y (apt upgrade) succeeds"
$S install -y 2>&1 | tee /tmp/install.log
grep -q "foreign architectures enabled (i386)" /tmp/install.log || fail "no multiarch warning"
missing="$($S _missing -m /media/usb/mirror <"$LOG")"
[[ -z "$missing" ]] || { echo "$missing"; fail "404s with i386 enabled"; }
if grep -q 'binary-i386' "$LOG"; then fail "apt requested i386 indexes"; fi
upg="$(apt list --upgradable 2>/dev/null | tail -n +2)"
[[ "$upg" == libc6/* || "$upg" == *$'\n'libc6/* ]] || fail "expected libc6 to be kept back (multiarch pair), got: $upg"
grep -q "not upgraded (kept back):.*libc6" /tmp/install.log || fail "kept-back libc6 not reported"
grep -q "Multi-Arch: same packages must have the same version" /tmp/install.log || fail "no multiarch explanation"
[[ "$(count_i386)" -eq "$i386_before" ]] || fail "i386 packages changed"

echo "--- install -y --full-upgrade never removes i386 packages"
set +e; $S install -y --full-upgrade --no-snaps >/tmp/full.log 2>&1; rc=$?; set -e
grep -E '==>|WARN|ERROR' /tmp/full.log || true
if [[ $rc -ne 0 ]]; then
  grep -q "refusing to remove them unattended" /tmp/full.log || fail "full-upgrade failed (rc=$rc)"
fi
[[ "$(dpkg-query -W -f='${db:Status-Abbrev}' libc6:i386)" == ii* ]] || fail "libc6:i386 was removed"
[[ "$(count_i386)" -eq "$i386_before" ]] || fail "i386 packages changed"
echo "MULTIARCH OK"
EOS
grep -qx "MULTIARCH OK" "$WORK/client-i386.log" || fail "multiarch client test did not complete"

step "E2E PASSED"
