#!/usr/bin/env bash
# Node.js v22.18.0 builder for CentOS/RHEL 7 (cPanel-safe)
# Faster build, full logging, EL7 c-ares patch, SCL toolchain.
set -euo pipefail

NODE_VER="v22.18.0"
NODE_DIR="node-${NODE_VER}"
NODE_TGZ="${NODE_DIR}.tar.gz"
NODE_URL="https://nodejs.org/dist/${NODE_VER}/${NODE_TGZ}"

SRC_ROOT="/usr/local/src"
PREFIX="/opt/${NODE_DIR}"
LOG="/root/node_${NODE_VER}_build.log"

# ---- Tunables (override via env) ----
: "${MAKE_JOBS:=auto}"   # "auto" or number
: "${SWAP_GB:=0}"        # temporary swap in GB (0 = none)
: "${VERBOSE:=0}"        # 1 = very chatty (V=1)

# Compile flags aimed at faster *compile time*
CFLAGS_BASE="-O0 -g0 -pipe"
CXXFLAGS_BASE="-O0 -g0 -pipe"

# --- logging helpers (timestamps added by tee/awk below) ---
say(){ printf "\n%s\n" "$*"; }
die(){ say "ERROR: $*"; exit 1; }
require_root(){ [[ $EUID -eq 0 ]] || die "Run as root."; }
require_root

# Mirror stdout/stderr to console + log with timestamps
exec > >(stdbuf -oL -eL awk '{ print strftime("[%F %T]"), $0 }' | tee -a "${LOG}") \
     2> >(stdbuf -oL -eL awk '{ print strftime("[%F %T]"), $0 }' | tee -a "${LOG}" >&2)

say "Node ${NODE_VER} build starting. Log: ${LOG}"
ELREL="$(grep -Eo 'release [0-9]+' /etc/*release 2>/dev/null | head -n1 | awk '{print $2}')"
say "Detected EL release: ${ELREL:-unknown}"

phase_start(){ PHASE_NAME="$1"; PHASE_T0=$(date +%s); say "==> ${PHASE_NAME} START"; }
phase_end(){ local t1=$(date +%s); say "==> ${PHASE_NAME} DONE in $((t1-PHASE_T0))s"; }

# ---------- deps ----------
phase_start "Install deps (SCL toolchain, Python 3.8, build tools)"
yum -y install -q epel-release || true
yum -y install -q curl tar xz bzip2 make gcc gcc-c++ git perl || true
yum -y install -q centos-release-scl scl-utils || true
yum -y install -q devtoolset-11 devtoolset-11-gcc devtoolset-11-gcc-c++ devtoolset-11-binutils || true
yum -y install -q rh-python38 rh-python38-python-devel || true
phase_end

# ---------- optional temp swap ----------
add_swap() {
  local sz_gb="$1"
  [[ "${sz_gb}" -gt 0 ]] || return 0
  if [[ ! -f /swapfile_node22 ]]; then
    say "Adding temporary ${sz_gb}G swapfile for V8 compile"
    if ! fallocate -l "${sz_gb}G" /swapfile_node22 2>/dev/null; then
      dd if=/dev/zero of=/swapfile_node22 bs=1M count=$((sz_gb*1024))
    fi
    chmod 600 /swapfile_node22
    mkswap /swapfile_node22
    swapon /swapfile_node22
    say "Swap enabled at /swapfile_node22"
  fi
}
add_swap "${SWAP_GB}"

# ---------- parallelism heuristic ----------
auto_jobs() {
  local cpu mem_kb swap_kb per_job_mb=1700
  cpu=$(nproc 2>/dev/null || echo 1)
  mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
  swap_kb=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
  local max_by_mem=$(( ( (mem_kb + swap_kb) / 1024 ) / per_job_mb ))
  (( max_by_mem < 1 )) && max_by_mem=1
  local jobs=$(( cpu < max_by_mem ? cpu : max_by_mem ))
  (( jobs > 3 )) && jobs=3
  (( jobs < 1 )) && jobs=1
  echo "${jobs}"
}
[[ "${MAKE_JOBS}" == "auto" ]] && MAKE_JOBS="$(auto_jobs)"
say "Using MAKE_JOBS=${MAKE_JOBS}"

# ---------- fetch & unpack ----------
phase_start "Fetch Node ${NODE_VER} source"
mkdir -p "${SRC_ROOT}"
cd "${SRC_ROOT}"
[[ -f "${NODE_TGZ}" ]] || curl -fL "${NODE_URL}" -o "${NODE_TGZ}"
rm -rf "${NODE_DIR}" && tar -xzf "${NODE_TGZ}"
phase_end

# ---------- c-ares patch for EL7 ----------
phase_start "Patch c-ares for EL7 (disable sys/random.h & getrandom)"
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

# ---------- inner build script (to avoid SCL quoting issues) ----------
INNER="/root/.node22_build_inner.sh"
PYBIN="/opt/rh/rh-python38/root/usr/bin/python3"
[[ -x "${PYBIN}" ]] || PYBIN="$(command -v python3 || true)"
[[ -x "${PYBIN}" ]] || die "python3 not found"

CFLAGS="${CFLAGS_BASE} -fno-omit-frame-pointer -fno-strict-aliasing -U_FORTIFY_SOURCE -UHAVE_SYS_RANDOM_H -UHAVE_GETRANDOM"
CXXFLAGS="${CXXFLAGS_BASE} -fno-rtti -fno-exceptions -fno-omit-frame-pointer -fno-strict-aliasing -U_FORTIFY_SOURCE -UHAVE_SYS_RANDOM_H -UHAVE_GETRANDOM"
VFLAG=$([[ "${VERBOSE}" == "1" ]] && echo "V=1" || echo "V=0")

cat > "${INNER}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "${SRC_ROOT}/${NODE_DIR}"

export CC=gcc CXX=g++
export CFLAGS="${CFLAGS}"
export CXXFLAGS="${CXXFLAGS}"
export LDFLAGS="${LDFLAGS:-} -Wl,--no-as-needed"
export ARFLAGS="cr"
export PYTHON="${PYBIN}"

echo "Using Python: \${PYTHON}"
make -s distclean >/dev/null 2>&1 || true

echo "Configuring (intl=none, prefix=${PREFIX})"
./configure --prefix="${PREFIX}" --with-intl=none

echo "Building Node (jobs=${MAKE_JOBS}, ${VFLAG}) — this can take a while"
make -j"${MAKE_JOBS}" ${VFLAG}

echo "Installing to ${PREFIX}"
make install
EOF
chmod +x "${INNER}"

# ---------- compile & install ----------
phase_start "Compile & install"
if command -v scl >/dev/null 2>&1 && scl -l | grep -q devtoolset-11; then
  # run inside SCL to get GCC 11 & Python 3.8
  scl enable devtoolset-11 rh-python38 -- bash "${INNER}"
else
  say "[!] SCL not detected; building with system toolchain"
  bash "${INNER}"
fi
phase_end

# ---------- symlinks ----------
phase_start "Create symlinks"
ln -sf "${PREFIX}/bin/node" /usr/local/bin/node
ln -sf "${PREFIX}/bin/npm"  /usr/local/bin/npm
ln -sf "${PREFIX}/bin/npx"  /usr/local/bin/npx
phase_end

# ---------- verify ----------
phase_start "Verify installation"
node -v
npm -v || true
phase_end

say "SUCCESS: Node ${NODE_VER} installed at ${PREFIX}"
say "Symlinks: /usr/local/bin/{node,npm,npx}"
say "Log: ${LOG}"
if [[ -f /swapfile_node22 ]]; then
  say "Temporary swapfile /swapfile_node22 is enabled."
  echo "To remove later:  swapoff /swapfile_node22 && rm -f /swapfile_node22"
fi
