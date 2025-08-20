#!/usr/bin/env bash
# Node.js v22.18.0 builder for CentOS/RHEL 7 (cPanel-safe)
# Faster build, fully logged, EL7 c-ares patch, SCL toolchain.

set -euo pipefail

NODE_VER="v22.18.0"
NODE_DIR="node-${NODE_VER}"
NODE_TGZ="${NODE_DIR}.tar.gz"
NODE_URL="https://nodejs.org/dist/${NODE_VER}/${NODE_TGZ}"

SRC_ROOT="/usr/local/src"
PREFIX="/opt/${NODE_DIR}"
LOG="/root/node_${NODE_VER}_build.log"

# ---- Tunables (override via env when calling) ----
: "${MAKE_JOBS:=auto}"      # "auto" or a number; try 2–3 for speed if you have RAM
: "${SWAP_GB:=0}"           # 0 = no temp swap; set 4 or 8 if RAM is tight
: "${VERBOSE:=0}"           # 1 = very chatty build logs (V=1 + shell tracing)

# Compile flags aimed at faster compile time (lower CPU/RAM)
CFLAGS_BASE="-O0 -g0 -pipe"
CXXFLAGS_BASE="-O0 -g0 -pipe"

# --------------------------------------------------
say()  { printf "\n[%(%F %T)T] %s\n" -1 "$*"; }
die()  { say "ERROR: $*"; exit 1; }

require_root() { [[ $EUID -eq 0 ]] || die "Run as root."; }
require_root

# Start log early and mirror to console
exec > >(stdbuf -oL -eL awk '{ print strftime("[%F %T]"), $0 }' | tee -a "${LOG}") \
     2> >(stdbuf -oL -eL awk '{ print strftime("[%F %T]"), $0 }' | tee -a "${LOG}" >&2)
say "Node ${NODE_VER} build starting. Log: ${LOG}"

# Simple phase timer
phase_start() { PHASE_NAME="$1"; PHASE_T0=$(date +%s); say "==> ${PHASE_NAME} START"; }
phase_end()   { local t1=$(date +%s); say "==> ${PHASE_NAME} DONE in $((t1-PHASE_T0))s"; }

# Detect EL version (informational)
ELREL="$(grep -Eo 'release [0-9]+' /etc/*release 2>/dev/null | head -n1 | awk '{print $2}')"
say "Detected EL release: ${ELREL:-unknown} (OK if unknown)"

# Dependencies
phase_start "Install deps (SCL toolchain, Python 3.8, build tools)"
yum -y install -q epel-release || true
yum -y install -q curl tar xz bzip2 make gcc gcc-c++ git perl || true
yum -y install -q centos-release-scl scl-utils || true
yum -y install -q devtoolset-11 devtoolset-11-gcc devtoolset-11-gcc-c++ devtoolset-11-binutils || true
yum -y install -q rh-python38 rh-python38-python-devel || true
phase_end

# Optional temp swap
add_swap() {
  local sz_gb="$1"
  [[ "${sz_gb}" -gt 0 ]] || return 0
  if [[ ! -f /swapfile_node22 ]]; then
    say "Adding temporary ${sz_gb}G swapfile to reduce OOM risk during V8 build"
    fallocate -l "${sz_gb}G" /swapfile_node22 || dd if=/dev/zero of=/swapfile_node22 bs=1M count=$((sz_gb*1024))
    chmod 600 /swapfile_node22
    mkswap /swapfile_node22
    swapon /swapfile_node22
    say "Swap enabled at /swapfile_node22"
  fi
}
add_swap "${SWAP_GB}"

# Choose parallelism
auto_jobs() {
  local cpu mem_kb swap_kb mem_gb total_gb per_job_mb=1700
  cpu=$(nproc 2>/dev/null || echo 1)
  mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
  swap_kb=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
  mem_gb=$(( (mem_kb + 1023) / 1024 / 1024 ))
  total_gb=$(( (mem_kb + swap_kb + 1023) / 1024 / 1024 ))
  # Conservative heuristic: ~1.7GB per job
  local max_by_mem=$(( ( (mem_kb + swap_kb) / 1024 ) / per_job_mb ))
  (( max_by_mem < 1 )) && max_by_mem=1
  local jobs=$(( cpu < max_by_mem ? cpu : max_by_mem ))
  (( jobs > 3 )) && jobs=3         # cap for EL7 boxes
  (( jobs < 1 )) && jobs=1
  echo "${jobs}"
}

if [[ "${MAKE_JOBS}" == "auto" ]]; then
  MAKE_JOBS="$(auto_jobs)"
fi
say "Using MAKE_JOBS=${MAKE_JOBS}  (override: MAKE_JOBS=N)"; sleep 1

# Download & unpack
phase_start "Fetch Node ${NODE_VER} source"
mkdir -p "${SRC_ROOT}"
cd "${SRC_ROOT}"
[[ -f "${NODE_TGZ}" ]] || curl -fL "${NODE_URL}" -o "${NODE_TGZ}"
rm -rf "${NODE_DIR}" && tar -xzf "${NODE_TGZ}"
phase_end

# Patch c-ares (EL7 lacks sys/random.h & getrandom)
phase_start "Patch c-ares for EL7 (disable sys/random.h/getrandom)"
cd "${SRC_ROOT}/${NODE_DIR}"
ARES_CFG="deps/cares/config/linux/ares_config.h"
if [[ -f "${ARES_CFG}" ]]; then
  sed -ri 's/^(#\s*define\s+HAVE_SYS_RANDOM_H\b.*)$/#undef HAVE_SYS_RANDOM_H/' "${ARES_CFG}" || true
  sed -ri 's/^(#\s*define\s+HAVE_GETRANDOM\b.*)$/#undef HAVE_GETRANDOM/' "${ARES_CFG}" || true
  grep -q 'HAVE_SYS_RANDOM_H' "${ARES_CFG}" || echo '#undef HAVE_SYS_RANDOM_H' >> "${ARES_CFG}"
  grep -q 'HAVE_GETRANDOM'    "${ARES_CFG}" || echo '#undef HAVE_GETRANDOM'    >> "${ARES_CFG}"
else
  say "[!] ${ARES_CFG} not found — will inject -U defines during build."
fi
phase_end

# Build inside SCL env
build() {
  local cflags="$1" cxxflags="$2" jobs="$3" verbose="$4"

  export CC=gcc CXX=g++
  export CFLAGS="${cflags} -fno-omit-frame-pointer -fno-strict-aliasing -U_FORTIFY_SOURCE -UHAVE_SYS_RANDOM_H -UHAVE_GETRANDOM"
  export CXXFLAGS="${cxxflags} -fno-rtti -fno-exceptions -fno-omit-frame-pointer -fno-strict-aliasing -U_FORTIFY_SOURCE -UHAVE_SYS_RANDOM_H -UHAVE_GETRANDOM"
  export LDFLAGS="${LDFLAGS:-} -Wl,--no-as-needed"
  export ARFLAGS="cr"

  # Python for GYP
  PYBIN="/opt/rh/rh-python38/root/usr/bin/python3"
  [[ -x "${PYBIN}" ]] || PYBIN="$(command -v python3 || true)"
  [[ -x "${PYBIN}" ]] || die "python3 not found"
  export PYTHON="${PYBIN}"
  say "Using Python: ${PYTHON}"

  say "Running configure (intl=none, prefix=${PREFIX})"
  make -s distclean >/dev/null 2>&1 || true
  time ./configure --prefix="${PREFIX}" --with-intl=none

  say "Building Node (jobs=${jobs}, verbose=${verbose}) — this phase is the long one"
  local VFLAG="V=0"; [[ "${verbose}" == "1" ]] && VFLAG="V=1"
  # GNU make on EL7 is 3.82 (no --output-sync). We still stream logs live.
  time make -j"${jobs}" ${VFLAG}
  say "Installing to ${PREFIX}"
  time make install
}

phase_start "Compile & install"
BUILD_VERBOSE="${VERBOSE}"

if command -v scl >/dev/null 2>&1 && scl -l | grep -q devtoolset-11; then
  # Run the whole build inside SCL bash
  scl enable devtoolset-11 rh-python38 -- bash -lc "
    set -euo pipefail
    cd '${SRC_ROOT}/${NODE_DIR}'
    $(declare -f say die build)
    build '${CFLAGS_BASE}' '${CXXFLAGS_BASE}' '${MAKE_JOBS}' '${BUILD_VERBOSE}'
  "
else
  say "[!] SCL not detected; building with system toolchain"
  build "${CFLAGS_BASE}" "${CXXFLAGS_BASE}" "${MAKE_JOBS}" "${BUILD_VERBOSE}"
fi
phase_end

# Symlinks
phase_start "Create symlinks"
ln -sf "${PREFIX}/bin/node" /usr/local/bin/node
ln -sf "${PREFIX}/bin/npm"  /usr/local/bin/npm
ln -sf "${PREFIX}/bin/npx"  /usr/local/bin/npx
phase_end

# Verify
phase_start "Verify installation"
node -v
npm -v || true
phase_end

say "SUCCESS: Node ${NODE_VER} installed at ${PREFIX}"
say "Binary symlinks -> /usr/local/bin/{node,npm,npx}"
say "Full build log at: ${LOG}"

if [[ -f /swapfile_node22 ]]; then
  say "Temporary swapfile /swapfile_node22 is still enabled."
  echo "To remove later:  swapoff /swapfile_node22 && rm -f /swapfile_node22"
fi
