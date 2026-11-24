#!/usr/bin/env bash
# ubuntu-airgap.sh - Offline (airgap) update mirror for Ubuntu 26.04 "resolute"
#
#   ONLINE machine : ./ubuntu-airgap.sh download --dest /mnt/usb/mirror [options]
#                    Starts an ubuntu:26.04 docker container that builds a REAL
#                    Ubuntu mirror (dists/ + pool/, original signed InRelease) with
#                    debmirror, plus any extra repositories you add.
#
#   AIRGAP machine : sudo /mnt/usb/mirror/ubuntu-airgap.sh install
#                    Serves the mirror with "python3 -m http.server", points apt
#                    at it (signature checked with the normal Ubuntu keyring),
#                    runs apt update + upgrade.
#
# Run "./ubuntu-airgap.sh help" for all options.

set -Eeuo pipefail
trap 'printf "ERROR: unexpected failure at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

VERSION="0.2.3"
SCRIPT_NAME="ubuntu-airgap.sh"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
SELF_DIR="$(dirname "$SELF")"

# ----------------------------------------------------------------------------
# Defaults (override with options or a --config file)
# ----------------------------------------------------------------------------
DEST=""
RELEASE="resolute"
BASE_IMAGE="ubuntu:26.04"
UBUNTU_HOST="archive.ubuntu.com"
UBUNTU_ROOT="ubuntu"
UBUNTU_METHOD="http"
SUITES=""                                  # default: $RELEASE, -updates, -security
COMPONENTS="main,restricted,universe,multiverse"
ARCHES="amd64"
AMD64V3=0                                  # 1 = also mirror amd64v3 (x86-64-v3 optimised builds)
BACKPORTS=0
CONTENTS=0                                 # Contents-* files (only needed for apt-file)
PACKAGE_FILTER=""                          # regex: only download matching .debs (testing/partial)
DRY_RUN=0
REPOS=()                                   # extra repos, see help
PPAS=()                                    # Launchpad PPAs, e.g. git-core/ppa
REPO_DEBS=()                               # "repo setup" .deb files/URLs (vendor packages that add a repo)
SNAPS=()                                   # snaps to download: NAME or NAME=CHANNEL
DEBMIRROR_EXTRA=()

PORT=8080
BIND="127.0.0.1"
MIRROR_DIR=""
UPGRADE_CMD="upgrade"                      # upgrade | full-upgrade
ASSUME_YES=0
NO_UPGRADE=0
KEEP_SERVING=0
PHASED_ALL=1
INSTALL_SETUP_DEBS=0
NO_SNAPS=0

SOURCES_FILE="/etc/apt/sources.list.d/ubuntu-airgap.sources"
APT_CONF_FILE="/etc/apt/apt.conf.d/90ubuntu-airgap"
PREFS_PREFIX="/etc/apt/preferences.d/ubuntu-airgap-"
KEYRING_DIR="/etc/apt/keyrings"
BACKUP_ROOT="/var/backups/ubuntu-airgap"
MANIFEST_NAME="airgap-mirror.conf"
SERVER_LOG="/var/log/ubuntu-airgap-http.log"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then C_B=$'\e[1m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_0=$'\e[0m'
else C_B=""; C_G=""; C_Y=""; C_R=""; C_0=""; fi
# curl retries transient errors (timeouts, 408/429/5xx) with exponential
# backoff for up to 15 min, so a short server outage does not fail a download
CURL_RETRY=(--retry 10 --retry-max-time 900)

log()  { printf '%s==>%s %s\n' "$C_G$C_B" "$C_0" "$*"; }
warn() { printf '%sWARNING:%s %s\n' "$C_Y$C_B" "$C_0" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$C_R$C_B" "$C_0" "$*" >&2; exit 1; }
csv_to_space() { tr ',' ' ' <<<"$1" | xargs; }

usage() {
cat <<EOF
${C_B}ubuntu-airgap.sh $VERSION${C_0} - offline Ubuntu mirror + airgap upgrader

${C_B}COMMANDS${C_0}
  download   (online machine)  Build/refresh the mirror in a docker container.
  install    (airgap machine)  Serve the mirror, configure apt, update + upgrade,
                               then install/refresh the snaps from the mirror.
  snaps      (airgap machine)  Only install/refresh the snaps from the mirror.
  serve      (airgap machine)  Only serve the mirror over HTTP (foreground).
  restore    (airgap machine)  Remove the offline apt config, restore original sources.
  version                      Print the version.
  help                         This text.

${C_B}DOWNLOAD OPTIONS${C_0}
  -d, --dest DIR            Where the mirror is written (required). Re-running only
                            fetches what changed and removes outdated packages.
  -c, --config FILE         Read settings from a bash-style config file (see
                            airgap.conf.example). Command-line options win.
  --release NAME            Ubuntu codename (default: $RELEASE)
  --suites LIST             Comma list (default: RELEASE,RELEASE-updates,RELEASE-security)
  --backports               Also mirror RELEASE-backports
  --components LIST         Default: $COMPONENTS
  --amd64v3                 Also mirror the amd64v3 variant (x86-64-v3 optimised
                            builds for CPUs with AVX2/BMI2/FMA). Clients use them
                            automatically when their CPU supports x86-64-v3.
  --contents                Also mirror Contents-* files (for apt-file; big)
  --ubuntu-mirror URL       Upstream Ubuntu mirror (default: http://$UBUNTU_HOST/$UBUNTU_ROOT)
  --repo SPEC               Add an extra repository (repeatable). SPEC is
                            "name=NAME;url=URL;suites=S1,S2;components=C1,C2;key=KEY"
                            KEY is a URL or local file with the repo's signing key
                            (ASCII-armored or binary). Must be a normal (non-flat)
                            repository with a dists/ directory.
  --ppa OWNER/NAME          Add a Launchpad PPA, same as "add-apt-repository
                            ppa:OWNER/NAME" (repeatable). The signing key is looked
                            up on Launchpad and its fingerprint verified.
  --repo-deb URL|FILE       Add the repositories that a "repo setup" .deb would
                            configure, e.g. a hardware vendor's *-install_*.deb (repeatable).
                            The .deb is unpacked (not installed); its apt sources,
                            keys and apt pinning (preferences.d) are used, and the
                            .deb itself is stored in the mirror (setup-debs/).
  --snap NAME[=CHANNEL]     Download a snap (repeatable), e.g. --snap firefox or
                            --snap firefox=latest/beta. Its base, content snaps
                            (default-providers) and snapd are added automatically.
                            Downloaded with their signed .assert files.
  --package-filter REGEX    Only download .deb files whose path matches REGEX (all
                            index files are still mirrored). For tests/partial mirrors.
  --image IMAGE             Docker base image (default: $BASE_IMAGE)
  --dry-run                 Fetch indexes only and report how much would be downloaded.
  --debmirror-arg ARG       Pass an extra argument to debmirror (repeatable).

${C_B}INSTALL / SERVE OPTIONS${C_0}
  -m, --mirror DIR          Mirror directory (default: the directory holding this
                            script, if it contains $MANIFEST_NAME)
  -p, --port PORT           HTTP port (default: $PORT)
  --bind ADDR               Bind address for serve (default: $BIND; use 0.0.0.0 to
                            share the mirror with other airgapped machines on the LAN)
  --full-upgrade            Use "apt full-upgrade" instead of "apt upgrade"
  -y, --yes                 Do not ask for confirmation
  --no-upgrade              Configure + apt update only
  --keep-serving            Keep the HTTP server running after the upgrade (Ctrl-C ends)
  --no-phased-all           Respect Ubuntu phased updates (default: install all updates)
  --no-snaps                Do not install/refresh snaps (install command)
  --install-setup-debs      Also install the .deb files from --repo-deb (e.g. to get
                            vendor's install tool). Their online sources are
                            disabled again automatically.

${C_B}EXAMPLES${C_0}
  # Online: full mirror for 26.04 amd64 + docker repo, onto a USB disk
  ./ubuntu-airgap.sh download -d /media/\$USER/USB/mirror \\
     --repo "name=docker;url=https://download.docker.com/linux/ubuntu;suites=resolute;components=stable;key=https://download.docker.com/linux/ubuntu/gpg"

  # Online: add a PPA and the repositories from a vendor's repo-setup package
  ./ubuntu-airgap.sh download -d /media/\$USER/USB/mirror --ppa git-core/ppa \\
     --repo-deb https://example.com/downloads/vendor-repo-setup_1.0_all.deb

  # Check the size first
  ./ubuntu-airgap.sh download -d /media/\$USER/USB/mirror --dry-run

  # Airgap: configure + upgrade
  sudo /media/\$USER/USB/mirror/ubuntu-airgap.sh install
EOF
}

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------
CMD="${1:-help}"; [[ $# -gt 0 ]] && shift

# Load --config first so that command-line options override it
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [[ "${args[i]}" == "-c" || "${args[i]}" == "--config" ]]; then
    cfg="${args[i+1]:-}"; [[ -r "$cfg" ]] || die "cannot read config file '$cfg'"
    # shellcheck disable=SC1090
    source "$cfg"
  fi
done

while [[ $# -gt 0 ]]; do
  if [[ "$1" =~ ^(--[a-z0-9-]+)=(.*)$ ]]; then        # --opt=value  ->  --opt value
    set -- "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${@:2}"
  fi
  case "$1" in
    -d|--dest)          DEST="$2"; shift ;;
    -c|--config)        shift ;;
    --release)          RELEASE="$2"; shift ;;
    --suites)           SUITES="$2"; shift ;;
    --backports)        BACKPORTS=1 ;;
    --components)       COMPONENTS="$2"; shift ;;
    --amd64v3)          AMD64V3=1 ;;
    --contents)         CONTENTS=1 ;;
    --ubuntu-mirror)
      u="${2%/}"; UBUNTU_METHOD="${u%%://*}"; u="${u#*://}"
      UBUNTU_HOST="${u%%/*}"; UBUNTU_ROOT="${u#*/}"; [[ "$UBUNTU_ROOT" == "$u" ]] && UBUNTU_ROOT=""
      shift ;;
    --repo)             REPOS+=("$2"); shift ;;
    --ppa)              PPAS+=("${2#ppa:}"); shift ;;
    --repo-deb)         REPO_DEBS+=("$2"); shift ;;
    --install-setup-debs) INSTALL_SETUP_DEBS=1 ;;
    --snap)             SNAPS+=("$2"); shift ;;
    --no-snaps)         NO_SNAPS=1 ;;
    --package-filter)   PACKAGE_FILTER="$2"; shift ;;
    --image)            BASE_IMAGE="$2"; shift ;;
    --dry-run)          DRY_RUN=1 ;;
    --debmirror-arg)    DEBMIRROR_EXTRA+=("$2"); shift ;;
    -m|--mirror)        MIRROR_DIR="$2"; shift ;;
    -p|--port)          PORT="$2"; shift ;;
    --bind)             BIND="$2"; shift ;;
    --full-upgrade)     UPGRADE_CMD="full-upgrade" ;;
    -y|--yes)           ASSUME_YES=1 ;;
    --no-upgrade)       NO_UPGRADE=1 ;;
    --keep-serving)     KEEP_SERVING=1 ;;
    --no-phased-all)    PHASED_ALL=0 ;;
    -h|--help)          CMD=help ;;
    *) die "unknown option '$1' (see: $0 help)" ;;
  esac
  shift
done

[[ -z "$SUITES" ]] && SUITES="$RELEASE,$RELEASE-updates,$RELEASE-security"
[[ $BACKPORTS -eq 1 && ",$SUITES," != *",$RELEASE-backports,"* ]] && SUITES="$SUITES,$RELEASE-backports"
[[ $AMD64V3 -eq 1 && ",$ARCHES," != *",amd64v3,"* ]] && ARCHES="$ARCHES,amd64v3"

# Parse an extra-repo SPEC into R_NAME R_URL R_SUITES R_COMPONENTS R_KEY
parse_repo() {
  R_NAME=""; R_URL=""; R_SUITES=""; R_COMPONENTS=""; R_KEY=""
  local kv k v
  IFS=';' read -ra kvs <<<"$1"
  for kv in "${kvs[@]}"; do
    k="$(xargs <<<"${kv%%=*}")"; v="$(xargs <<<"${kv#*=}")"
    case "$k" in
      name) R_NAME="$v" ;; url) R_URL="${v%/}" ;; suites|suite) R_SUITES="$v" ;;
      components|component) R_COMPONENTS="$v" ;; key) R_KEY="$v" ;;
      "") ;; *) die "unknown key '$k' in --repo '$1'" ;;
    esac
  done
  [[ "$R_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "--repo needs name=NAME (letters, digits, . _ -): '$1'"
  [[ "$R_NAME" != "ubuntu" ]] || die "--repo name 'ubuntu' is reserved"
  [[ "$R_URL" =~ ^https?://[^/]+ ]] || die "--repo '$R_NAME' needs url=http(s)://..."
  [[ -n "$R_SUITES" ]] || die "--repo '$R_NAME' needs suites=..."
  [[ -n "$R_COMPONENTS" ]] || die "--repo '$R_NAME' needs components=... (flat repositories are not supported)"
  [[ -n "$R_KEY" ]] || die "--repo '$R_NAME' needs key=URL-or-file"
}

# ============================================================================
# DOWNLOAD (online host side)
# ============================================================================
docker_cmd() {
  if docker info >/dev/null 2>&1; then DOCKER=(docker)
  elif sudo -n docker info >/dev/null 2>&1 || sudo docker info >/dev/null; then DOCKER=(sudo docker)
  else die "docker is not usable (install it, or add yourself to the docker group)"; fi
}

cmd_download() {
  # Validate everything before touching docker
  [[ -n "$DEST" ]] || die "--dest DIR is required"
  local r p d
  for r in "${REPOS[@]}"; do
    parse_repo "$r"
    if [[ ! "$R_KEY" =~ ^https?:// && ! -r "$R_KEY" ]]; then
      die "key file '$R_KEY' for repo '$R_NAME' not readable"
    fi
  done
  for p in "${PPAS[@]}"; do
    [[ "$p" =~ ^[a-z0-9][a-z0-9.+-]*/[a-z0-9][a-z0-9.+-]*$ ]] || die "--ppa expects OWNER/NAME (e.g. git-core/ppa), got '$p'"
  done
  for p in "${SNAPS[@]}"; do
    [[ "$p" =~ ^[a-z0-9][a-z0-9-]*(=[a-z0-9][a-z0-9./-]*)?$ ]] \
      || die "--snap expects NAME or NAME=CHANNEL (e.g. firefox or firefox=latest/beta), got '$p'"
  done
  for d in "${REPO_DEBS[@]}"; do
    if [[ ! "$d" =~ ^https?:// ]] && [[ ! -r "$d" || "$d" != *.deb ]]; then
      die "--repo-deb '$d' is not a readable .deb file or http(s) URL"
    fi
  done
  command -v docker >/dev/null || die "docker is not installed"

  mkdir -p "$DEST"; DEST="$(readlink -f "$DEST")"
  docker_cmd

  local img="ubuntu-airgap-mirror:${BASE_IMAGE//[:\/]/-}"
  log "Preparing docker image $img (from $BASE_IMAGE)"
  "${DOCKER[@]}" build -q -t "$img" - >/dev/null <<EOF
FROM $BASE_IMAGE
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \\
      debmirror gpgv gnupg ca-certificates curl xz-utils bzip2 python3 python3-yaml \\
      ubuntu-keyring snapd squashfs-tools \\
    && rm -rf /var/lib/apt/lists/*
EOF

  # Key files given as local paths are mounted into the container
  local mounts=() i=0 newrepos=()
  for r in "${REPOS[@]}"; do
    parse_repo "$r"
    if [[ ! "$R_KEY" =~ ^https?:// ]]; then
      [[ -r "$R_KEY" ]] || die "key file '$R_KEY' for repo '$R_NAME' not readable"
      mounts+=(-v "$(readlink -f "$R_KEY"):/keys-in/$i:ro")
      r="${r/key=$R_KEY/key=/keys-in/$i}"
    fi
    newrepos+=("$r"); i=$((i + 1))
  done
  local newdebs=() d
  for d in "${REPO_DEBS[@]}"; do
    if [[ "$d" =~ ^https?:// ]]; then newdebs+=("$d")
    else
      [[ -r "$d" && "$d" == *.deb ]] || die "--repo-deb '$d' is not a readable .deb file or http(s) URL"
      mounts+=(-v "$(readlink -f "$d"):/debs-in/$i/$(basename "$d"):ro")
      newdebs+=("/debs-in/$i/$(basename "$d")"); i=$((i + 1))
    fi
  done

  local tty=(); [[ -t 1 ]] && tty=(-t)
  local flags=()
  if [[ $AMD64V3 -eq 1 ]]; then flags+=(--amd64v3); fi
  if [[ $CONTENTS -eq 1 ]]; then flags+=(--contents); fi
  if [[ $DRY_RUN -eq 1 ]]; then flags+=(--dry-run); fi
  log "Starting mirror container (output: $DEST)"
  "${DOCKER[@]}" run --rm -i "${tty[@]}" \
    --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -v "$DEST:/mirror" -v "$SELF:/opt/$SCRIPT_NAME:ro" "${mounts[@]}" \
    "$img" bash "/opt/$SCRIPT_NAME" _container \
      --release "$RELEASE" --suites "$SUITES" --components "$COMPONENTS" \
      --ubuntu-mirror "$UBUNTU_METHOD://$UBUNTU_HOST${UBUNTU_ROOT:+/$UBUNTU_ROOT}" \
      "${flags[@]}" \
      ${PACKAGE_FILTER:+--package-filter "$PACKAGE_FILTER"} \
      "${newrepos[@]/#/--repo=}" \
      "${SNAPS[@]/#/--snap=}" \
      "${PPAS[@]/#/--ppa=}" \
      "${newdebs[@]/#/--repo-deb=}" \
      "${DEBMIRROR_EXTRA[@]/#/--debmirror-arg=}"

  if [[ $DRY_RUN -eq 0 ]]; then
    cp -f "$SELF" "$DEST/$SCRIPT_NAME"; chmod +x "$DEST/$SCRIPT_NAME"
    log "Done. Mirror size: $(du -sh "$DEST" | cut -f1)"
    log "Copy '$DEST' to the airgap machine and run:  sudo <mirror>/$SCRIPT_NAME install"
  fi
}

# ============================================================================
# _container: runs inside the docker container (debmirror)
# ============================================================================
run_debmirror() {  # target method host root dists sections keyring arches
  local target="$1" method="$2" host="$3" root="$4" dists="$5" sections="$6" keyring="$7" arches="$8"
  local a=(
    --method="$method" --host="$host" --root="${root:-/}"
    --dist="$dists" --section="$sections" --arch="$arches"
    --nosource --i18n --diff=none --rsync-extra=none
    --keyring="$keyring" --verbose --timeout=300
    --ignore='/by-hash/'                 # by-hash links are managed by make_by_hash
  )
  [[ $CONTENTS -eq 1 ]] && a+=(--getcontents)
  [[ $DRY_RUN -eq 1 ]] && a+=(--dry-run)
  [[ -n "$PACKAGE_FILTER" ]] && a+=(--exclude='\.u?deb$' --include="$PACKAGE_FILTER")
  a+=("${DEBMIRROR_EXTRA[@]}")
  # debmirror refuses an empty result ("No packages after parsing") unless the
  # mirror directory is new, so let debmirror create it. With --package-filter a
  # repo may legitimately match nothing: start such a repo over each time,
  # including before each retry (a failed attempt leaves the directory behind).
  mkdir -p "$(dirname "$target")"
  log "debmirror $method://$host/$root  dists=$dists  sections=$sections  arch=$arches"
  # The archive republishes every ~30 min; a publish during the download makes
  # index checksums mismatch. A retry fetches the new, consistent set. Servers
  # also have short outages (503s): 5 attempts, 1/2/4/8 min apart (~15 min).
  # archive.ubuntu.com answers 403 Forbidden for pool/ files when the
  # User-Agent is LWP's default "libwww-perl/X" (debmirror has no option to
  # change it), so replace LWP's default agent via a tiny preloaded module.
  local ualib
  ualib="$(mktemp -d)"
  cat >"$ualib/AirgapUA.pm" <<'PERL'
package AirgapUA;
use LWP::UserAgent ();
no warnings 'redefine';
*LWP::UserAgent::_agent = sub { "debmirror (ubuntu-airgap)" };
1;
PERL
  local -x PERL5LIB="$ualib${PERL5LIB:+:$PERL5LIB}" PERL5OPT="-MAirgapUA${PERL5OPT:+ $PERL5OPT}"
  local try out delay
  out="$(mktemp)"
  for try in 1 2 3 4 5; do
    if [[ -n "$PACKAGE_FILTER" && -d "$target" ]] && [[ -z "$(find "$target" -name '*.deb' -print -quit)" ]]; then
      rm -rf "$target"
    fi
    if debmirror "${a[@]}" "$target" 2>&1 | tee "$out"; then rm -f "$out"; return 0; fi
    # Empty pocket: nothing in it matches --package-filter, but the directory
    # still holds .debs from an earlier run, so debmirror's anti-nuke check
    # refuses. Those .debs no longer match the filter (debmirror's cleanup
    # would delete them anyway), so mirror the pocket into a fresh directory.
    if [[ -n "$PACKAGE_FILTER" ]] && grep -q '^No packages after parsing' "$out"; then
      warn "no packages in $dists ($sections) match --package-filter; mirroring index files only"
      rm -rf "$target"
      if debmirror "${a[@]}" "$target" 2>&1 | tee "$out"; then rm -f "$out"; return 0; fi
    fi
    [[ $try -lt 5 ]] || break
    delay=$((60 * 2 ** (try - 1)))
    warn "debmirror failed (attempt $try/5), retrying in $((delay / 60)) min..."
    sleep "$delay"
  done
  rm -f "$out"
  die "debmirror failed for $method://$host/$root"
}

# Recreate dists/**/by-hash/SHA256/<hash> entries listed in Release files, like
# the real archive (apt asks for these first when Acquire-By-Hash: yes).
make_by_hash() {
  python3 -I - "$1" <<'PY'
import os, sys, shutil
root = sys.argv[1]
made = 0
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d != "by-hash"]
    if "Release" not in filenames:
        continue
    rel = os.path.join(dirpath, "Release")
    with open(rel, encoding="utf-8", errors="replace") as f:
        lines = f.read().splitlines()
    if not any(l.lower().startswith("acquire-by-hash:") and "yes" in l.lower() for l in lines):
        continue
    keep = {}
    section = None
    for l in lines:
        if l and not l.startswith(" "):
            section = l.split(":", 1)[0]
            continue
        if section != "SHA256" or not l.strip():
            continue
        h, _size, name = l.split()
        src = os.path.join(dirpath, name)
        if not os.path.isfile(src):
            continue
        d = os.path.join(os.path.dirname(src), "by-hash", "SHA256")
        keep.setdefault(d, set()).add(h)
        dst = os.path.join(d, h)
        if os.path.exists(dst):
            continue
        os.makedirs(d, exist_ok=True)
        try:
            os.link(src, dst)
        except OSError:            # e.g. exFAT/FAT: no hard links
            shutil.copyfile(src, dst)
        made += 1
    # drop by-hash entries that are no longer referenced
    for d, hashes in keep.items():
        for fn in os.listdir(d):
            if fn not in hashes:
                os.unlink(os.path.join(d, fn))
print(f"by-hash: {made} new entries")
PY
}

# Python helper (runs in the container):
#   ppa OWNER/NAME RELEASE WORKDIR -> prints one repo SPEC, key verified via Launchpad
#   deb FILE.deb WORKDIR           -> unpacks a repo-setup .deb, prints
#                                     "repo<TAB>SPEC" and "pref<TAB>FILE|NEWNAME" lines
PY_HELPER=$(cat <<'PY'
import glob
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request


def die(msg):
    print("ERROR: " + msg, file=sys.stderr)
    sys.exit(1)

def http_get(req, tries=8, sleep=time.sleep):
    """GET, retrying rate limits (429), server errors (5xx) and network errors.

    Honours Retry-After (capped at 300 s), else backs off 5, 10, 20 ... 300 s
    (about 10 minutes in all: the Snap Store can rate-limit for minutes).
    Other HTTP errors (404, ...) are raised at once.
    """
    for attempt in range(1, tries + 1):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code != 429 and e.code < 500:
                raise
            err, after = e, e.headers.get("Retry-After") if e.headers else None
        except (urllib.error.URLError, TimeoutError) as e:
            err, after = e, None
        if attempt == tries:
            raise err
        delay = int(after) if after and after.isdigit() else 5 * 2 ** (attempt - 1)
        delay = min(delay, 300)
        url = req.full_url if hasattr(req, "full_url") else req
        print(f"WARNING: {url}: {err}; retrying in {delay}s ({attempt}/{tries - 1})",
              file=sys.stderr)
        sleep(delay)


def fetch(url):
    return http_get(urllib.request.Request(url, headers={"User-Agent": "ubuntu-airgap"}))

def build_keyring(sources, out, only_fpr=None):
    """Import key files (armored/binary) and export one binary keyring."""
    home = tempfile.mkdtemp()
    for src in sources:
        subprocess.run(["gpg", "--homedir", home, "--batch", "--quiet", "--import", src],
                       capture_output=True, check=False)
    listing = subprocess.run(["gpg", "--homedir", home, "--batch", "--with-colons", "--list-keys"],
                             capture_output=True, text=True, check=False).stdout
    fprs = [l.split(":")[9] for l in listing.splitlines() if l.startswith("fpr:")]
    if only_fpr:
        if only_fpr.upper() not in (f.upper() for f in fprs):
            die(f"downloaded key does not have fingerprint {only_fpr}")
        fprs = [only_fpr]
    if not fprs:
        die("no usable OpenPGP keys found in: " + ", ".join(sources))
    data = subprocess.run(["gpg", "--homedir", home, "--batch", "--export"] + fprs,
                          capture_output=True, check=True).stdout
    with open(out, "wb") as f:
        f.write(data)
    return out

def spec(**kw):
    return ";".join(f"{k}={v}" for k, v in kw.items())

def ppa(ppa_spec, release, work):
    owner, name = ppa_spec.split("/", 1)
    try:
        info = json.loads(fetch(f"https://api.launchpad.net/1.0/~{owner}/+archive/ubuntu/{name}"))
    except (OSError, ValueError) as e:  # network errors, bad JSON
        die(f"PPA ppa:{ppa_spec} not found on Launchpad ({e})")
    fpr = info.get("signing_key_fingerprint")
    if not fpr:
        die(f"PPA ppa:{ppa_spec} has no signing key (private or empty PPA?)")
    raw = os.path.join(work, f"ppa-{owner}-{name}.asc")
    with open(raw, "wb") as f:
        f.write(fetch(f"https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&exact=on&search=0x{fpr}"))
    key = build_keyring([raw], os.path.join(work, f"ppa-{owner}-{name}.gpg"), only_fpr=fpr)
    print(spec(name=f"ppa-{owner}-{name}", url=f"https://ppa.launchpadcontent.net/{owner}/{name}/ubuntu",
               suites=release, components="main", key=key))

def parse_one_line(path):
    out = []
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.read().splitlines()
    for line in lines:
        line = line.split("#", 1)[0].strip()
        if not line.startswith("deb "):
            continue
        opts = {}
        m = re.match(r"deb\s+\[([^\]]*)\]\s+(.*)", line)
        if m:
            for o in m.group(1).split():
                if "=" in o:
                    k, v = o.split("=", 1)
                    opts[k] = v
            rest = m.group(2).split()
        else:
            rest = line.split()[1:]
        if len(rest) < 2:
            continue
        out.append({"uris": [rest[0]], "suites": [rest[1]], "comps": rest[2:],
                    "arch": opts.get("arch", ""), "signed_by": opts.get("signed-by", "")})
    return out

def parse_deb822(path):
    out = []
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    for para in re.split(r"\n\s*\n", text):
        fields, cur = {}, None
        for line in para.splitlines():
            if line.startswith("#"):
                continue
            if line[:1] in (" ", "\t") and cur:
                fields[cur] += "\n" + line.strip()
            elif ":" in line:
                cur, v = line.split(":", 1)
                cur = cur.strip().lower()
                fields[cur] = v.strip()
        if "deb" not in fields.get("types", "").split() or fields.get("enabled", "yes").lower() == "no":
            continue
        out.append({"uris": fields.get("uris", "").split(),
                    "suites": fields.get("suites", "").split(),
                    "comps": fields.get("components", "").split(),
                    "arch": ",".join(fields.get("architectures", "").split()),
                    "signed_by": fields.get("signed-by", "")})
    return out

def deb(debfile, work):
    pkg = subprocess.run(["dpkg-deb", "-f", debfile, "Package"], capture_output=True, text=True,
                         check=True).stdout.strip()
    x = os.path.join(work, "x-" + pkg)
    subprocess.run(["dpkg-deb", "-x", debfile, x], check=True)
    entries = []
    for f in sorted(glob.glob(x + "/etc/apt/sources.list.d/*.list")) + glob.glob(x + "/etc/apt/sources.list"):
        entries += parse_one_line(f)
    for f in sorted(glob.glob(x + "/etc/apt/sources.list.d/*.sources")):
        entries += parse_deb822(f)
    if not entries:
        die(f"{os.path.basename(debfile)} does not contain any apt sources (etc/apt/sources.list.d)")
    all_keys = [k for d in ("etc/apt/keyrings", "etc/apt/trusted.gpg.d", "usr/share/keyrings")
                for k in sorted(glob.glob(os.path.join(x, d, "*"))) if os.path.isfile(k)]
    groups = {}
    for e in entries:
        if e["arch"] and not {"amd64", "all"} & set(e["arch"].split(",")):
            print(f"WARNING: skipping {e['uris']} (arch={e['arch']}, no amd64)", file=sys.stderr)
            continue
        sb = e["signed_by"]
        if sb.startswith("-----BEGIN") or "\n" in sb:          # inline key (deb822)
            p = os.path.join(work, f"{pkg}-inline-{len(groups)}.asc")
            with open(p, "w") as f:
                f.write("\n".join("" if l == "." else l for l in sb.splitlines()) + "\n")
            keysrc = (p,)
        elif sb.startswith("/"):
            files = [os.path.join(x, s.lstrip("/")) for s in sb.split(",")]
            missing = [f for f in files if not os.path.isfile(f)]
            if missing:
                die(f"{pkg}: signed-by key {sb} is not shipped inside the .deb; use --repo with key=...")
            keysrc = tuple(files)
        else:                                                  # no signed-by / fingerprints
            if not all_keys:
                die(f"{pkg}: no signing key found inside the .deb; use --repo with key=...")
            keysrc = tuple(all_keys)
        for uri in e["uris"]:
            for suite in e["suites"]:
                if suite.endswith("/"):
                    die(f"{pkg}: flat repository '{uri} {suite}' is not supported")
                k = (uri.rstrip("/"), suite, keysrc)
                groups.setdefault(k, [])
                groups[k] += [c for c in e["comps"] if c not in groups[k]]
    for n, ((uri, suite, keysrc), comps) in enumerate(groups.items(), 1):
        name = f"{pkg}-{n}"
        key = build_keyring(list(keysrc), os.path.join(work, name + ".gpg"))
        print("repo\t" + spec(name=name, url=uri, suites=suite, components=",".join(comps), key=key))
    for p in sorted(glob.glob(x + "/etc/apt/preferences.d/*")) + glob.glob(x + "/etc/apt/preferences"):
        if os.path.isfile(p):
            print(f"pref\t{p}|{pkg}-{os.path.basename(p)}")

SNAP_API = "https://api.snapcraft.io/v2/snaps/info/"
NO_BASE_TYPES = {"base", "os", "snapd", "kernel"}


def snap_channel(info, channel):
    """Pick the amd64 channel-map entry for 'risk' or 'track/risk'."""
    track, _, risk = channel.rpartition("/")
    track = track or info.get("default-track") or "latest"
    for cm in info["channel-map"]:
        c = cm["channel"]
        if c["architecture"] == "amd64" and c["track"] == track and c["risk"] == risk:
            return cm
    die(f"snap {info['name']}: no amd64 release in channel {track}/{risk}")


def store_get(req, tries=8, sleep=time.sleep):
    """GET JSON from the Snap Store (retried like http_get)."""
    return json.loads(http_get(req, tries, sleep))


def snap_resolve(specs):
    """Resolve snaps + their bases/default-providers; print them deps-first."""
    import yaml  # python3-yaml in the download container

    order, seen = [], set()

    def visit(name, channel):
        if name in seen:
            return
        seen.add(name)
        req = urllib.request.Request(
            SNAP_API + name + "?architecture=amd64&fields=revision,version,type,confinement,base,snap-yaml",
            headers={"Snap-Device-Series": "16", "User-Agent": "ubuntu-airgap"})
        try:
            info = store_get(req)
        except urllib.error.HTTPError as e:
            if e.code == 404:
                die(f"snap {name} not found in the Snap Store")
            die(f"Snap Store query for {name} failed ({e})")
        except (OSError, ValueError) as e:
            die(f"Snap Store query for {name} failed ({e})")
        cm = snap_channel(info, channel)
        meta = yaml.safe_load(cm.get("snap-yaml") or "") or {}
        stype = cm.get("type") or meta.get("type") or "app"
        deps = []
        if stype not in NO_BASE_TYPES:
            deps.append(cm.get("base") or meta.get("base") or "core")
        for plug in (meta.get("plugs") or {}).values():
            if isinstance(plug, dict) and plug.get("default-provider"):
                deps.append(str(plug["default-provider"]).split(":")[0])
        for dep in deps:
            visit(dep, "latest/stable")
        order.append((name, channel, cm["revision"], cm.get("confinement") or "strict", stype))

    visit("snapd", "latest/stable")            # newer snaps need a recent snapd
    for spec in specs:
        name, _, channel = spec.partition("=")
        visit(name.strip(), channel.strip() or "latest/stable")
    for row in order:
        print("\t".join(str(x) for x in row))


if __name__ == "__main__":
    if sys.argv[1] == "ppa":
        ppa(sys.argv[2], sys.argv[3], sys.argv[4])
    elif sys.argv[1] == "deb":
        deb(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == "snaps":
        snap_resolve(sys.argv[2:])
PY
)

# Turn --ppa and --repo-deb into plain --repo specs (before the big download, so
# mistakes fail fast). Also stores setup .debs and apt pin files in the mirror.
expand_extras() {
  local m="$1" manifest="$2" p d f s kind val work=/tmp/airgap-expand
  rm -rf "$work"; mkdir -p "$work"
  if [[ $DRY_RUN -eq 0 ]]; then rm -rf "$m/prefs" "$m/setup-debs"; fi
  for p in "${PPAS[@]}"; do
    log "Resolving PPA ppa:$p"
    s="$(python3 -I -c "$PY_HELPER" ppa "$p" "$RELEASE" "$work")" || die "cannot resolve ppa:$p"
    REPOS+=("$s")
  done
  for d in "${REPO_DEBS[@]}"; do
    log "Reading repository setup package $d"
    if [[ "$d" =~ ^https?:// ]]; then
      f="$work/$(basename "${d%%\?*}")"
      curl -fsSL "${CURL_RETRY[@]}" -o "$f" "$d" || die "cannot download $d"
    else f="$d"; fi
    python3 -I -c "$PY_HELPER" deb "$f" "$work" >"$work/out.tsv" || die "cannot use $d"
    while IFS=$'\t' read -r kind val; do
      case "$kind" in
        repo) REPOS+=("$val"); parse_repo "$val"; log "  found repo $R_NAME: $R_URL $R_SUITES [$R_COMPONENTS]" ;;
        pref)
          if [[ $DRY_RUN -eq 0 ]]; then
            mkdir -p "$m/prefs"; cp -f "${val%%|*}" "$m/prefs/${val#*|}"
            echo "pref|prefs/${val#*|}" >>"$manifest"
          fi
          log "  found apt pinning file ${val#*|}" ;;
      esac
    done <"$work/out.tsv"
    if [[ $DRY_RUN -eq 0 ]]; then
      mkdir -p "$m/setup-debs"; cp -f "$f" "$m/setup-debs/"
      echo "setupdeb|setup-debs/$(basename "$f")" >>"$manifest"
    fi
  done
}

# "snap download NAME" into DIR, retrying failures (the Snap Store rate-limits
# and has transient errors): up to 5 attempts, 10/20/40/80 s apart.
snap_download() {  # name channel dir
  local name="$1" ch="$2" dir="$3" try
  for try in 1 2 3 4 5; do
    rm -rf "${dir:?}"/* 2>/dev/null || true
    if (cd "$dir" && snap download "$name" --channel="$ch" >/dev/null); then return 0; fi
    [[ $try -lt 5 ]] || break
    warn "snap download $name failed (attempt $try/5), retrying in $((10 * 2 ** (try - 1)))s..."
    sleep $((10 * 2 ** (try - 1)))
  done
  return 1
}

# Check that NAME's suite has dists/SUITE/InRelease or Release. Only a 404
# means "not found"; outages are retried (CURL_RETRY) and reported as such.
check_repo_suite() {  # name url suite
  local name="$1" url="$2" s="$3" f code err=""
  for f in InRelease Release; do
    code="$(curl -sS "${CURL_RETRY[@]}" -o /dev/null -w '%{http_code}' "$url/dists/$s/$f" 2>/dev/null)" || true
    [[ "$code" == 200 ]] && return 0
    [[ "$code" == 404 ]] || err="${code:-000}"
  done
  [[ -n "$err" ]] && die "repo '$name': cannot reach $url/dists/$s/ (HTTP $err; 000 = no connection)"
  die "repo '$name': $url/dists/$s/(In)Release not found (flat repos are not supported)"
}

# Download snaps (+ dependencies) with "snap download" (works without snapd
# running). Each .snap comes with a .assert file holding its signed assertions.
fetch_snaps() {
  local m="$1" manifest="$2" dir="$1/snaps" name ch rev conf type f tmpd keep=() total=0
  if [[ ${#SNAPS[@]} -eq 0 ]]; then
    if [[ $DRY_RUN -eq 0 ]]; then rm -rf "$dir"; fi
    return 0
  fi
  log "Resolving snaps: ${SNAPS[*]}"
  python3 -I -c "$PY_HELPER" snaps "${SNAPS[@]}" >/tmp/snaps.tsv || die "cannot resolve snaps"
  mkdir -p "$dir"
  while IFS=$'\t' read -r name ch rev conf type; do
    if [[ $DRY_RUN -eq 1 ]]; then log "  snap $name $ch r$rev ($type, $conf)"; continue; fi
    if [[ -s "$dir/${name}_$rev.snap" && -s "$dir/${name}_$rev.assert" ]]; then
      log "  snap $name $ch r$rev ($type, $conf) - already downloaded"
    else
      log "  snap $name $ch r$rev ($type, $conf) - downloading"
      tmpd="$(mktemp -d "$dir/.dl.XXXXXX")"
      snap_download "$name" "$ch" "$tmpd" || die "snap download $name failed"
      f="$(find "$tmpd" -name "${name}_*.snap" -print -quit)"
      [[ -n "$f" && -f "${f%.snap}.assert" ]] || die "snap download $name produced no .snap/.assert"
      rev="$(basename "$f" .snap)"; rev="${rev##*_}"      # store may have moved on
      chmod 644 "$f" "${f%.snap}.assert"
      mv -f "$f" "${f%.snap}.assert" "$dir/"
      rm -rf "$tmpd"
    fi
    keep+=("${name}_$rev.snap" "${name}_$rev.assert")
    total=$((total + $(stat -c %s "$dir/${name}_$rev.snap")))
    echo "snap|$name|snaps/${name}_$rev.snap|snaps/${name}_$rev.assert|$ch|$conf|$type" >>"$manifest"
  done </tmp/snaps.tsv
  if [[ $DRY_RUN -eq 0 ]]; then
    for f in "$dir"/* "$dir"/.dl.*; do                       # drop old revisions
      [[ -e "$f" ]] || continue
      [[ " ${keep[*]} " == *" $(basename "$f") "* ]] || rm -rf "$f"
    done
    log "Snaps: ${#keep[@]} files, $((total / 1048576)) MiB"
  fi
}

cmd_container() {
  local m=/mirror manifest_tmp
  mkdir -p "$m/keys"
  manifest_tmp="$m/.$MANIFEST_NAME.tmp"
  {
    echo "# ubuntu-airgap mirror manifest - generated $(date -u +%FT%TZ)"
    echo "# type|name|path|suites|components|keyfile"
    echo "arches|$ARCHES"
  } >"$manifest_tmp"

  expand_extras "$m" "$manifest_tmp"

  # --- Ubuntu archive ------------------------------------------------------
  cp -f /usr/share/keyrings/ubuntu-archive-keyring.gpg "$m/keys/ubuntu-archive-keyring.gpg"
  run_debmirror "$m/ubuntu" "$UBUNTU_METHOD" "$UBUNTU_HOST" "$UBUNTU_ROOT" \
    "$SUITES" "$COMPONENTS" /usr/share/keyrings/ubuntu-archive-keyring.gpg "$ARCHES"
  echo "repo|ubuntu|ubuntu|$(csv_to_space "$SUITES")|$(csv_to_space "$COMPONENTS")|ubuntu-archive-keyring.gpg" >>"$manifest_tmp"

  # --- Extra repositories --------------------------------------------------
  local r method rest host root key
  for r in "${REPOS[@]}"; do
    parse_repo "$r"
    method="${R_URL%%://*}"; rest="${R_URL#*://}"
    host="${rest%%/*}"; root="${rest#*/}"; [[ "$root" == "$rest" ]] && root=""
    key="$m/keys/$R_NAME.gpg"
    log "Fetching signing key for '$R_NAME'"
    if [[ "$R_KEY" =~ ^http:// ]]; then
      warn "key for '$R_NAME' is downloaded over plain http - prefer an https:// key URL"
    fi
    if [[ "$R_KEY" =~ ^https?:// ]]; then curl -fsSL "${CURL_RETRY[@]}" "$R_KEY" -o /tmp/key.in || die "cannot download key $R_KEY"
    else cp "$R_KEY" /tmp/key.in; fi
    if grep -q -- "-----BEGIN PGP" /tmp/key.in; then gpg --batch --yes --dearmor -o "$key" /tmp/key.in
    else cp /tmp/key.in "$key"; fi
    for s in $(csv_to_space "$R_SUITES"); do check_repo_suite "$R_NAME" "$R_URL" "$s"; done
    run_debmirror "$m/repos/$R_NAME" "$method" "$host" "$root" "$R_SUITES" "$R_COMPONENTS" "$key" amd64
    echo "repo|$R_NAME|repos/$R_NAME|$(csv_to_space "$R_SUITES")|$(csv_to_space "$R_COMPONENTS")|$R_NAME.gpg" >>"$manifest_tmp"
  done

  fetch_snaps "$m" "$manifest_tmp"

  if [[ $DRY_RUN -eq 1 ]]; then rm -f "$manifest_tmp"; log "Dry run finished (nothing downloaded besides indexes)"; return; fi

  log "Creating by-hash index links"
  make_by_hash "$m"
  mv -f "$manifest_tmp" "$m/$MANIFEST_NAME"
}

# ============================================================================
# AIRGAP side
# ============================================================================
need_root() { [[ $EUID -eq 0 ]] || die "run as root: sudo $0 $CMD ..."; }

find_mirror() {
  if [[ -z "$MIRROR_DIR" ]]; then
    if [[ -f "$SELF_DIR/$MANIFEST_NAME" ]]; then MIRROR_DIR="$SELF_DIR"
    else die "no $MANIFEST_NAME next to the script - use --mirror DIR"; fi
  fi
  MIRROR_DIR="$(readlink -f "$MIRROR_DIR")"
  [[ -f "$MIRROR_DIR/$MANIFEST_NAME" ]] || die "'$MIRROR_DIR' is not a mirror (missing $MANIFEST_NAME)"
}

SERVER_PID=""
start_server() {
  command -v python3 >/dev/null || die "python3 not found"
  if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
    die "port $PORT is already in use (choose another with --port)"
  fi
  local runas=()
  # serve as the invoking user, not as root, when possible
  if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]] \
     && runuser -u "$SUDO_USER" -- test -r "$MIRROR_DIR/$MANIFEST_NAME" 2>/dev/null; then
    runas=(runuser -u "$SUDO_USER" --)
  fi
  # Never write to a predictable /tmp path (symlink attacks): fall back to mktemp
  if ! { [[ $EUID -eq 0 && ! -L "$SERVER_LOG" ]] && : >"$SERVER_LOG"; } 2>/dev/null; then
    SERVER_LOG="$(mktemp -t ubuntu-airgap-http.XXXXXX.log)"
  fi
  log "Serving $MIRROR_DIR on http://$BIND:$PORT/ (log: $SERVER_LOG)"
  "${runas[@]}" python3 -m http.server "$PORT" --bind "$BIND" --directory "$MIRROR_DIR" \
      >>"$SERVER_LOG" 2>&1 &
  SERVER_PID=$!
  trap stop_server EXIT INT TERM
  for _ in $(seq 50); do
    (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && return 0
    kill -0 "$SERVER_PID" 2>/dev/null || { cat "$SERVER_LOG" >&2; die "http.server failed to start"; }
    sleep 0.2
  done
  die "http.server did not start listening on port $PORT"
}
stop_server() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true
    log "HTTP server stopped"
  fi
  SERVER_PID=""
}

backup_sources() {
  # Disable all online apt sources by moving them into a backup directory.
  # The first run creates the backup; later runs also sweep up sources that were
  # added since (e.g. by installing a vendor repo-setup .deb), into the same backup.
  local b f moved=0
  if [[ -f "$BACKUP_ROOT/ACTIVE" ]]; then
    b="$(cat "$BACKUP_ROOT/ACTIVE")"
  else
    b="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$b/sources.list.d"
    echo "$b" >"$BACKUP_ROOT/ACTIVE"
    log "Disabling online apt sources (backup: $b)"
  fi
  mkdir -p "$b/sources.list.d"
  if grep -q -E '^[[:space:]]*deb' /etc/apt/sources.list 2>/dev/null; then
    cp -a --backup=numbered /etc/apt/sources.list "$b/sources.list"
    printf '# Disabled by ubuntu-airgap.sh - original saved in %s\n' "$b" >/etc/apt/sources.list
    moved=1
  fi
  shopt -s nullglob
  for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ "$f" == "$SOURCES_FILE" ]] && continue
    mv --backup=numbered "$f" "$b/sources.list.d/"
    moved=1; log "  disabled $f"
  done
  shopt -u nullglob
  if [[ $moved -eq 0 ]]; then log "Online apt sources are disabled (backup: $b)"; fi
}

write_apt_config() {
  local url="http://127.0.0.1:$PORT" type name path suites comps key keypath arch v3=0
  mkdir -p "$KEYRING_DIR"
  grep -q '^arches|.*amd64v3' "$MIRROR_DIR/$MANIFEST_NAME" && v3=1
  log "Writing $SOURCES_FILE"
  {
    echo "# Generated by ubuntu-airgap.sh from $MIRROR_DIR"
    echo "# Served by: sudo $SCRIPT_NAME serve   (python3 http.server on port $PORT)"
    while IFS='|' read -r type name path suites comps key; do
      [[ "$type" == repo ]] || continue
      if [[ "$name" == ubuntu && -f /usr/share/keyrings/ubuntu-archive-keyring.gpg ]]; then
        keypath=/usr/share/keyrings/ubuntu-archive-keyring.gpg
      else
        keypath="$KEYRING_DIR/airgap-$name.gpg"
        install -m 0644 "$MIRROR_DIR/keys/$key" "$keypath"
      fi
      # "amd64 amd64v3" lets apt pick the x86-64-v3 build when the CPU supports it
      # (APT::Architecture-Variants "auto"); listing only amd64 disables variants.
      arch=amd64; [[ "$name" == ubuntu && $v3 -eq 1 ]] && arch="amd64 amd64v3"
      printf '\nTypes: deb\nURIs: %s/%s/\nSuites: %s\nComponents: %s\nArchitectures: %s\nSigned-By: %s\nCheck-Valid-Until: no\n' \
        "$url" "$path" "$suites" "$comps" "$arch" "$keypath"
    done <"$MIRROR_DIR/$MANIFEST_NAME"
  } >"$SOURCES_FILE"

  # apt pinning shipped by repo setup packages (e.g. "Pin: release o=Vendor" priority 600)
  rm -f "$PREFS_PREFIX"*
  local pref
  while IFS='|' read -r type pref; do
    [[ "$type" == pref ]] || continue
    install -m 0644 "$MIRROR_DIR/$pref" "$PREFS_PREFIX$(basename "$pref")"
    log "Installed apt pinning $PREFS_PREFIX$(basename "$pref")"
  done <"$MIRROR_DIR/$MANIFEST_NAME"

  log "Writing $APT_CONF_FILE"
  {
    echo "// Generated by ubuntu-airgap.sh"
    echo "Acquire::Retries \"1\";"
    if [[ $PHASED_ALL -eq 1 ]]; then echo "APT::Get::Always-Include-Phased-Updates \"true\";"; fi
    if [[ $v3 -eq 1 ]]; then echo "APT::Architecture-Variants \"auto\";   // use amd64v3 builds if this CPU supports them"; fi
  } >"$APT_CONF_FILE"
}

preflight_warnings() {
  local fa n
  fa="$(dpkg --print-foreign-architectures 2>/dev/null | xargs || true)"
  if [[ -n "$fa" ]]; then
    n="$(foreign_installed | wc -l)"
    warn "foreign architectures enabled ($fa) with $n installed package(s); the mirror is amd64 only:"
    warn "  those packages are not upgraded, and Multi-Arch: same pairs (e.g. libc6 + libc6:i386)"
    warn "  must stay at the same version, so their amd64 half is kept back too."
  fi
  if command -v snap >/dev/null && snap list >/dev/null 2>&1 && ! grep -q '^snap|' "$MIRROR_DIR/$MANIFEST_NAME"; then
    warn "this mirror contains no snaps; installed snaps are not updated (download with --snap NAME)"
  fi
  local rel; rel="$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release 2>/dev/null | tr -d '"' || true)"
  grep -q "^repo|ubuntu|ubuntu|.*\b$rel\b" "$MIRROR_DIR/$MANIFEST_NAME" \
    || warn "this system is '$rel' but the mirror's Ubuntu suites are: $(grep '^repo|ubuntu|' "$MIRROR_DIR/$MANIFEST_NAME" | cut -d'|' -f4)"
}

# installed packages of a foreign (non-amd64) architecture, as NAME:ARCH
foreign_installed() {
  dpkg-query -W -f='${db:Status-Abbrev} ${Package}:${Architecture}\n' 2>/dev/null \
    | awk '$1 ~ /^[ih]i/ && $2 !~ /:(amd64|all)$/ {print $2}'
}

# After the upgrade: list what apt could not upgrade from this mirror, and why
report_kept_back() {
  local left
  left="$(apt list --upgradable 2>/dev/null | awk -F/ 'NR>1 {print $1}' | xargs || true)"
  [[ -n "$left" ]] || return 0
  warn "not upgraded (kept back): $left"
  if [[ -n "$(foreign_installed)" ]]; then
    warn "  likely because their i386/foreign counterparts are installed but not in the mirror"
    warn "  (Multi-Arch: same packages must have the same version on all architectures)"
  fi
}

# Paths the mirror answered with 404, minus apt's normal fallback: a missing
# dists/SUITE/InRelease when Release.gpg is there (debmirror keeps the
# Release + Release.gpg pair when an upstream InRelease could not be fetched).
missing_on_mirror() {  # server-log mirror-dir
  local path
  { grep '" 404 ' "$1" 2>/dev/null || true; } | sed -E 's/.*"GET ([^ ?]+)[^ ]* .*/\1/' | sort -u \
    | while IFS= read -r path; do
        [[ "$path" == */dists/*/InRelease && -s "$2${path%InRelease}Release.gpg" ]] && continue
        printf '%s\n' "$path"
      done
}

report_404() {
  local missing n
  missing="$(missing_on_mirror "$SERVER_LOG" "$MIRROR_DIR")"
  [[ -n "$missing" ]] || return 0
  n="$(wc -l <<<"$missing")"
  warn "$n path(s) were not found on the mirror (see $SERVER_LOG):"
  head -20 <<<"$missing" | sed 's/^/    /' >&2
}

# When amd64v3 is enabled, apt reinstalls installed amd64 packages as their
# amd64v3 build of the SAME version and lists them under "DOWNGRADING".
# With -y apt refuses that unless --allow-downgrades is given, so allow it only
# when every "downgrade" is such a same-version variant switch.
# Classify "apt-get -s" output (stdin) into lines:
#   switch|PKG              same version reinstalled (amd64v3 variant switch)
#   down|PKG OLD -> NEW     real downgrade
#   fremove|PKG:ARCH        removal of a foreign-architecture package
classify_sim() {
  local line pkg old new
  local re_inst='^Inst ([^ ]+) \[([^]]+)\] \(([^ ]+) '   # Inst NAME [OLD] (NEW Origin/suite [arch])
  local re_remv='^Remv ([^ ]+:[a-z0-9]+) '                  # Remv NAME:ARCH [VER] (native arch has no :ARCH)
  while read -r line; do
    if [[ "$line" =~ $re_remv ]]; then
      if [[ "${BASH_REMATCH[1]}" != *:amd64 ]]; then echo "fremove|${BASH_REMATCH[1]}"; fi
      continue
    fi
    [[ "$line" =~ $re_inst ]] || continue
    pkg="${BASH_REMATCH[1]}"; old="${BASH_REMATCH[2]}"; new="${BASH_REMATCH[3]}"
    if [[ "$old" == "$new" ]]; then echo "switch|$pkg"
    elif dpkg --compare-versions "$new" lt "$old"; then echo "down|$pkg $old -> $new"; fi
  done
}

ALLOW_VARIANT_SWITCH=()
check_variant_switches() {
  ALLOW_VARIANT_SWITCH=()
  local sim cls kind val switch=0 real=() fremove=()
  local simcmd=(apt-get -s "$UPGRADE_CMD")
  [[ "$UPGRADE_CMD" == upgrade ]] && simcmd+=(-o APT::Get::Upgrade-Allow-New=true)
  sim="$("${simcmd[@]}" 2>/dev/null)" || return 0
  cls="$(classify_sim <<<"$sim")"
  # full-upgrade may remove i386 packages (e.g. Wine/Steam libs) to upgrade
  # their amd64 Multi-Arch: same twin - never do that unattended
  while IFS='|' read -r kind val; do
    case "$kind" in
      switch)  switch=$((switch + 1)) ;;
      down)    real+=("$val") ;;
      fremove) fremove+=("$val") ;;
    esac
  done <<<"$cls"
  if [[ ${#fremove[@]} -gt 0 ]]; then
    warn "apt $UPGRADE_CMD would REMOVE ${#fremove[@]} foreign-architecture package(s), because"
    warn "their architecture is not in the mirror: ${fremove[*]:0:15}"
    if [[ $ASSUME_YES -eq 1 ]]; then
      die "refusing to remove them unattended; use plain 'install' (apt upgrade) or run without -y"
    fi
  fi
  if [[ ${#real[@]} -gt 0 ]]; then
    warn "the mirror would DOWNGRADE ${#real[@]} package(s) (is the mirror older than this system?):"
    printf '    %s\n' "${real[@]:0:20}" >&2
    return 0
  fi
  if [[ $switch -gt 0 ]]; then
    log "$switch installed package(s) will be switched to their optimised amd64v3 build"
    log "(same version; apt lists them under DOWNGRADING - that is expected)"
    ALLOW_VARIANT_SWITCH=(--allow-downgrades)
  fi
}

# Install/refresh the snaps on the mirror: ack their signed assertions first,
# then install in dependency order (as written by the download). Only signed
# installs - no --dangerous.
install_snaps() {
  local type name file assert ch conf stype cur rev flags failed=0
  grep -q '^snap|' "$MIRROR_DIR/$MANIFEST_NAME" || return 0
  if ! command -v snap >/dev/null; then warn "mirror has snaps but snap is not installed; skipping"; return 0; fi
  if ! snap list >/dev/null 2>&1; then warn "mirror has snaps but snapd is not running; skipping"; return 0; fi
  log "Snaps: importing signed assertions"
  while IFS='|' read -r type name file assert _ <&3; do
    [[ "$type" == snap ]] || continue
    snap ack "$MIRROR_DIR/$assert" || die "snap ack failed for $name ($assert)"
  done 3<"$MIRROR_DIR/$MANIFEST_NAME"
  while IFS='|' read -r type name file assert ch conf stype <&3; do
    [[ "$type" == snap ]] || continue
    rev="$(basename "$file" .snap)"; rev="${rev##*_}"
    cur="$(snap list "$name" 2>/dev/null | awk 'NR==2 {print $3}' || true)"
    if [[ "$cur" == "$rev" ]]; then log "snap $name is already at revision $rev"; continue; fi
    if [[ "$cur" =~ ^[0-9]+$ && "$cur" -gt "$rev" ]]; then
      log "snap $name: installed revision $cur is newer than the mirror ($rev); skipping"; continue
    fi
    flags=(); if [[ "$conf" == classic ]]; then flags+=(--classic); fi
    log "snap $name ($stype, $ch): ${cur:-not installed} -> revision $rev"
    snap install "${flags[@]}" "$MIRROR_DIR/$file" || { warn "snap install $name failed"; failed=1; }
  done 3<"$MIRROR_DIR/$MANIFEST_NAME"
  [[ $failed -eq 0 ]] || die "some snaps failed to install"
}

cmd_snaps() {
  need_root; find_mirror
  log "Mirror: $MIRROR_DIR"
  install_snaps
}

cmd_install() {
  need_root; find_mirror
  log "Mirror: $MIRROR_DIR"
  sed -n 's/^# ubuntu-airgap mirror manifest - generated /    built: /p' "$MIRROR_DIR/$MANIFEST_NAME"
  grep '^repo|' "$MIRROR_DIR/$MANIFEST_NAME" | awk -F'|' '{printf "    %-28s %s [%s]\n", $2, $4, $5}'
  preflight_warnings
  backup_sources
  write_apt_config
  start_server

  log "apt-get update"
  apt-get update || { report_404; die "apt-get update failed"; }
  report_404

  if [[ $INSTALL_SETUP_DEBS -eq 1 ]]; then
    local debs=() p
    while IFS='|' read -r type p; do
      [[ "$type" == setupdeb ]] || continue
      # already installed (maybe newer, from the mirrored repo): don't reinstall
      # the bundled copy, apt would see it as a downgrade
      local pkg; pkg="$(dpkg-deb -f "$MIRROR_DIR/$p" Package)"
      if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
        log "Setup package $pkg is already installed; skipping"
      else
        debs+=("$MIRROR_DIR/$p")
      fi
    done <"$MIRROR_DIR/$MANIFEST_NAME"
    if [[ ${#debs[@]} -gt 0 ]]; then
      log "Installing repo setup packages: ${debs[*]##*/}"
      # copy first: apt's sandbox user may not be able to read the mirror medium
      local tmpd; tmpd="$(mktemp -d)"; cp "${debs[@]}" "$tmpd/"; chmod 755 "$tmpd"; chmod 644 "$tmpd"/*.deb
      DEBIAN_FRONTEND=noninteractive apt-get install -y "$tmpd"/*.deb
      rm -rf "$tmpd"
      backup_sources              # disable the online sources they just added
      apt-get update || { report_404; die "apt-get update failed"; }
    elif ! grep -q '^setupdeb|' "$MIRROR_DIR/$MANIFEST_NAME"; then
      warn "--install-setup-debs: this mirror contains no setup packages"
    fi
  fi

  if [[ $NO_UPGRADE -eq 1 ]]; then
    log "--no-upgrade given; skipping upgrade"
  else
    local yes=(); [[ $ASSUME_YES -eq 1 ]] && yes=(-y)
    check_variant_switches
    log "apt $UPGRADE_CMD"
    DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-$([[ $ASSUME_YES -eq 1 ]] && echo noninteractive || echo readline)}" \
      apt "$UPGRADE_CMD" "${yes[@]}" "${ALLOW_VARIANT_SWITCH[@]}"
    report_404
    report_kept_back
    if [[ -f /var/run/reboot-required ]]; then warn "a reboot is required to finish the upgrade"; fi
  fi

  if [[ $NO_SNAPS -eq 0 ]]; then install_snaps; fi

  if [[ $KEEP_SERVING -eq 1 ]]; then
    log "Still serving (you can now 'apt install' from the mirror). Press Ctrl-C to stop."
    wait "$SERVER_PID" || true
  fi
  log "Done. Offline sources stay configured; next time just run '$SCRIPT_NAME install'"
  log "with a newer mirror. Use '$SCRIPT_NAME restore' to return to the original sources."
}

cmd_serve() {
  find_mirror
  start_server
  log "Serving until Ctrl-C. apt on this machine uses $SOURCES_FILE."
  if [[ "$BIND" != 127.0.0.1 ]]; then log "Other machines: URIs: http://<this-host-ip>:$PORT/ubuntu/  (see $MANIFEST_NAME for extra repos)"; fi
  wait "$SERVER_PID" || true
}

cmd_restore() {
  need_root
  rm -f "$SOURCES_FILE" "$APT_CONF_FILE" "$KEYRING_DIR"/airgap-*.gpg "$PREFS_PREFIX"*
  if [[ -f "$BACKUP_ROOT/ACTIVE" ]]; then
    local b; b="$(cat "$BACKUP_ROOT/ACTIVE")"
    if [[ -f "$b/sources.list" ]]; then cp -a "$b/sources.list" /etc/apt/sources.list; fi
    shopt -s nullglob; for f in "$b"/sources.list.d/*; do mv "$f" /etc/apt/sources.list.d/; done; shopt -u nullglob
    rm -f "$BACKUP_ROOT/ACTIVE"
    log "Original apt sources restored from $b"
  else
    warn "no backup found; removed offline configuration only"
  fi
}

case "$CMD" in
  download)   cmd_download ;;
  _container) cmd_container ;;
  _classify-sim) classify_sim ;;          # internal, used by tests
  _missing)   missing_on_mirror /dev/stdin "${MIRROR_DIR:?-m DIR}" ;;  # internal, tests: log on stdin
  install)    cmd_install ;;
  snaps)      cmd_snaps ;;
  serve)      cmd_serve ;;
  restore)    cmd_restore ;;
  version|--version|-V) echo "$SCRIPT_NAME $VERSION" ;;
  help|-h|--help) usage ;;
  *) die "unknown command '$CMD' (see: $0 help)" ;;
esac
