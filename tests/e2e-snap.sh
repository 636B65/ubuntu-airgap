#!/usr/bin/env bash
# End-to-end test for snaps: download a small snap (+ its base and snapd) with
# --snap, then install it with "ubuntu-airgap.sh snaps" in an Ubuntu 26.04
# container that runs systemd + snapd and has its network DISCONNECTED.
#
#   tests/e2e-snap.sh            (needs docker with --privileged)
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${IMAGE:-ubuntu:26.04}"
WORK="${WORK:-$(mktemp -d)}"
SNAP="${SNAP:-hello-world}"
IMG="ubuntu-airgap-e2e-snapd:latest"
CT="ubuntu-airgap-e2e-snapd-$$"

if docker info >/dev/null 2>&1; then DOCKER=(docker); else DOCKER=(sudo docker); fi
step() { printf '\n\033[1;34m### %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }
cleanup() { "${DOCKER[@]}" rm -f "$CT" >/dev/null 2>&1 || true; }
trap cleanup EXIT

step "Download a minimal mirror with --snap $SNAP"
mkdir -p "$WORK"
# Only one small suite and no .deb files: this test is about snaps
"$root/ubuntu-airgap.sh" download -d "$WORK/mirror" --suites resolute-security --components main \
  --package-filter '^$' --snap "$SNAP" >"$WORK/download.log" 2>&1 \
  || { tail -40 "$WORK/download.log"; fail "download failed"; }
grep -E '^==>' "$WORK/download.log"
M="$WORK/mirror"
grep -q "^snap|snapd|" "$M/airgap-mirror.conf" || fail "snapd not added as dependency"
grep -q "^snap|$SNAP|" "$M/airgap-mirror.conf" || fail "$SNAP not in manifest"
while IFS='|' read -r type _ snapf assertf _; do
  [[ "$type" == snap ]] || continue
  [[ -s "$M/$snapf" && -s "$M/$assertf" ]] || fail "missing $snapf or $assertf"
done <"$M/airgap-mirror.conf"

step "Second download is incremental"
"$root/ubuntu-airgap.sh" download -d "$WORK/mirror" --suites resolute-security --components main \
  --package-filter '^$' --snap "$SNAP" >"$WORK/download2.log" 2>&1 || fail "second download failed"
grep -q "already downloaded" "$WORK/download2.log" || fail "snaps were downloaded again"

step "Start systemd + snapd container"
"${DOCKER[@]}" build -q -t "$IMG" - >/dev/null <<EOF
FROM $IMAGE
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \\
      systemd systemd-sysv snapd squashfs-tools fuse3 udev ca-certificates \\
 && rm -rf /var/lib/apt/lists/*
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
EOF
"${DOCKER[@]}" run -d --name "$CT" --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock \
  -v "$M:/media/usb/mirror:ro" "$IMG" >/dev/null
for _ in $(seq 60); do
  "${DOCKER[@]}" exec "$CT" snap list >/dev/null 2>&1 && break; sleep 2
done
"${DOCKER[@]}" exec "$CT" snap version | sed -n 1,2p   # not head: SIGPIPE under pipefail

step "Disconnect the network (air gap)"
"${DOCKER[@]}" network disconnect bridge "$CT"

step "Offline: install snaps from the mirror"
"${DOCKER[@]}" exec -i -e SNAP="$SNAP" "$CT" bash -s <<'EOS' | tee "$WORK/client.log"
set -Eeuo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
S=/media/usb/mirror/ubuntu-airgap.sh
M=/media/usb/mirror
if getent hosts api.snapcraft.io >/dev/null 2>&1; then fail "container still has network/DNS"; fi

$S snaps

echo "--- installed revisions match the mirror"
while IFS='|' read -r type name file _; do
  [[ "$type" == snap ]] || continue
  want="$(basename "$file" .snap)"; want="${want##*_}"
  have="$(snap list "$name" | awk 'NR==2 {print $3}')"
  [[ "$have" == "$want" ]] || fail "$name: installed r$have, mirror r$want"
  pub="$(snap list "$name" | awk 'NR==2 {print $5}')"
  [[ "$pub" == *canonical* ]] || [[ -n "$pub" && "$pub" != "-" ]] || fail "$name has no verified publisher"
  echo "$name r$have ($pub)"
done <"$M/airgap-mirror.conf"

echo "--- the snap runs"
if [[ "$SNAP" == hello-world ]]; then
  out="$(snap run hello-world 2>&1 || true)"
  if [[ "$out" == "Hello World!" ]]; then
    echo "hello-world ran: $out"
  elif [[ "$out" == *aa_is_enabled* || "$out" == *apparmor* ]]; then
    # snap-confine cannot use the host's AppArmor from inside a container
    # (e.g. GitHub runners); the install itself is what is tested here
    echo "snap run unavailable in this container ($out); checking the mounted snap instead"
    [[ -x /snap/hello-world/current/bin/echo ]] || fail "hello-world is not mounted"
  else
    fail "hello-world output: $out"
  fi
fi

echo "--- second run is a no-op"
out="$($S snaps 2>&1)"; echo "$out"
[[ "$out" == *"already at revision"* ]] || fail "second run reinstalled snaps"
echo "SNAP CLIENT OK"
EOS
grep -qx "SNAP CLIENT OK" "$WORK/client.log" || fail "snap client test did not complete"

# --- Refresh: an installed snap is updated offline to a newer revision -------
# "hello" has different revisions in latest/stable and latest/edge.
rev_of() { awk -F'|' -v n="$1" '$1=="snap" && $2==n {f=$3; sub(/.*_/,"",f); sub(/\.snap$/,"",f); print f}' "$M/airgap-mirror.conf"; }
dl() { "$root/ubuntu-airgap.sh" download -d "$M" --suites resolute-security --components main \
         --package-filter '^$' --snap "$SNAP" --snap "$1" >>"$WORK/download-refresh.log" 2>&1 \
       || { tail -30 "$WORK/download-refresh.log"; fail "download $1 failed"; }; }

step "Refresh: mirror hello=latest/stable, install offline"
dl hello=latest/stable
old="$(rev_of hello)"
"${DOCKER[@]}" exec "$CT" /media/usb/mirror/ubuntu-airgap.sh snaps
have="$("${DOCKER[@]}" exec "$CT" snap list hello | awk 'NR==2 {print $3}')"
[[ "$have" == "$old" ]] || fail "hello: installed r$have, expected r$old"

step "Refresh: mirror hello=latest/edge, update offline"
dl hello=latest/edge
new="$(rev_of hello)"
if [[ "$new" == "$old" ]]; then
  echo "stable and edge are both r$new today - refresh path not exercised"
else
  [[ ! -e "$M/snaps/hello_$old.snap" ]] || fail "old revision r$old not removed from the mirror"
  "${DOCKER[@]}" exec "$CT" /media/usb/mirror/ubuntu-airgap.sh snaps | tee "$WORK/refresh.log"
  grep -q "snap hello .*: $old -> revision $new" "$WORK/refresh.log" || fail "no refresh r$old -> r$new logged"
  have="$("${DOCKER[@]}" exec "$CT" snap list hello | awk 'NR==2 {print $3}')"
  [[ "$have" == "$new" ]] || fail "hello not refreshed: installed r$have, expected r$new"
  echo "hello refreshed offline: r$old -> r$new"
fi

step "E2E SNAP PASSED"
