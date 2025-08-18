#!/usr/bin/env bash
# Build & install Node.js v22.18.0 on EL7/cPanel with ultra-low-memory settings.
# - Forces MAKE_JOBS=1
# - Adds swap (default 16G) if none is active
# - Uses -O1 -g0 (override with CXXFLAGS_OLEVEL=0 to use -O0)
# - Patches bundled c-ares to avoid sys/random.h/getrandom on EL7
# - Uses devtoolset-11 + rh-python38
# - Installs to /opt/node-v22.18.0 and exposes via /etc/profile.d

set -euo pipefail

# ---------- Tunables ----------
NODE_VER="${NODE_VER:-22.18.0}"
PREFIX="${PREFIX:-/opt/node-v${NODE_VER}}"
SRC_DIR="${SRC_DIR:-/usr/local/src}"
SWAPFILE="${SWAPFILE:-/swapfile}"
SWAP_SIZE_GB="${SWAP_SIZE_GB:-16}"        # Increase if you still OOM
MAKE_JOBS="1"                              # Force serial compile (best for RAM)
CXXFLAGS_OLEVEL="${CXXFLAGS_OLEVEL:-1}"    # 1 => -O1 (default), 0 => -O0
# ------------------------------

TARBALL="node-v${NODE_VER}.tar.xz"
TARBALL_URL="https://nodejs.org/dist/v${NODE_VER}/${TARBALL}"
BUILD_DIR="${SRC_DIR}/node-v${NODE_VER}"

log(){ printf "[%s] %s\n" "$(date +'%F %T')" "$*"; }

require_root(){
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then echo "Run as root."; exit 1; fi
}

detect_el7(){
  if [[ -f /etc/redhat-release ]] && grep -qE 'release 7(\.|$)' /etc/redhat-release; then
    return 0
  fi
  echo "This script targets RHEL/CentOS/CloudLinux 7."; exit 1
}

ensure_swap(){
  if swapon --show | awk 'NR>1 || (NR==1 && $1!~/^$|^Filename$/)' | grep -q .; then
    log "Swap already active:"
    swapon --show || true
    return
  fi

  log "No swap detected. Creating ${SWAP_SIZE_GB}G swap at ${SWAPFILE}…"
  fallocate -l "${SWAP_SIZE_GB}G" "${SWAPFILE}" 2>/dev/null || \
    dd if=/dev/zero of="${SWAPFILE}" bs=1M count=$((SWAP_SIZE_GB*1024))
  chmod 600 "${SWAPFILE}"
  mkswap "${SWAPFILE}"
  swapon "${SWAPFILE}"
  grep -q "${SWAPFILE}" /etc/fstab || echo "${SWAPFILE} none swap sw 0 0" >> /etc/fstab
  sysctl -w vm.swappiness=10 >/dev/null || true
  log "Swap ready:"
  swapon --show || true
}

install_prereqs(){
  log "Installing prerequisites…"
  yum -y install curl tar xz make perl gcc gcc-c++ python3 || true
  yum -y install centos-release-scl || true
  yum -y install devtoolset-11 rh-python38 || true
}

enable_toolchains(){
  # Enable SCL envs
  [[ -f /opt/rh/devtoolset-11/enable ]] && source /opt/rh/devtoolset-11/enable
  [[ -f /opt/rh/rh-python38/enable   ]] && source /opt/rh/rh-python38/enable

  # Pin Python for gyp
  if [[ -x /opt/rh/rh-python38/root/usr/bin/python3 ]]; then
    export PYTHON=/opt/rh/rh-python38/root/usr/bin/python3
  elif command -v python3 >/dev/null 2>&1; then
    export PYTHON="$(command -v python3)"
  else
    echo "Python 3 not found; install rh-python38 or python3."; exit 1
  fi
  export GYP_PYTHON="$PYTHON"

  log "Toolchains:"
  gcc --version | head -n1 || true
  "$PYTHON" --version || true
}

prepare_sources(){
  mkdir -p "$SRC_DIR"
  cd "$SRC_DIR"

  if [[ ! -f "$TARBALL" ]]; then
    log "Downloading Node.js v${NODE_VER} source…"
    curl -fsSLO "$TARBALL_URL"
  else
    log "Found source tarball: $TARBALL"
  fi

  if [[ ! -d "$BUILD_DIR" ]]; then
    log "Extracting ${TARBALL}…"
    tar -xf "$TARBALL"
  else
    log "Reusing existing source dir: $BUILD_DIR"
  fi
}

patch_cares_el7(){
  local cfg="${BUILD_DIR}/deps/cares/config/linux/ares_config.h"
  if [[ -f "$cfg" ]]; then
    log "Patching c-ares config for EL7 (disable sys/random.h & getrandom)…"
    sed -ri 's/^[[:space:]]*#define[[:space:]]+HAVE_SYS_RANDOM_H\b.*/#undef HAVE_SYS_RANDOM_H/' "$cfg" || true
    sed -ri 's/^[[:space:]]*#define[[:space:]]+HAVE_GETRANDOM\b.*/#undef HAVE_GETRANDOM/' "$cfg" || true
    grep -nE 'HAVE_(SYS_RANDOM_H|GETRANDOM)' "$cfg" || true
  else
    log "WARNING: ${cfg} not found; continuing."
  fi
}

configure_build(){
  cd "$BUILD_DIR"

  # Ultra-low-memory C/C++ flags
  case "$CXXFLAGS_OLEVEL" in
    0) OLEVEL="-O0" ;;
    1) OLEVEL="-O1" ;;
    *) OLEVEL="-O1" ;;
  esac

  export CFLAGS="${CFLAGS:-} ${OLEVEL} -g0"
  export CXXFLAGS="${CXXFLAGS:-} ${OLEVEL} -g0"
  # Avoid pipes (they can increase peak RAM usage in some environments)
  export CFLAGS="${CFLAGS} -fno-asynchronous-unwind-tables"
  export CXXFLAGS="${CXXFLAGS} -fno-asynchronous-unwind-tables"

  log "Configuring (prefix: ${PREFIX}) with Python: ${PYTHON} and CXXFLAGS: ${CXXFLAGS}"
  PYTHON="${PYTHON}" ./configure --prefix="${PREFIX}"
}

build_and_install(){
  cd "$BUILD_DIR"
  log "Building Node.js with MAKE_JOBS=${MAKE_JOBS} (this will be slow, but safe on RAM)…"
  make -j"${MAKE_JOBS}"

  log "Installing to ${PREFIX}…"
  make install

  ln -snf "${PREFIX}/bin/node" /usr/local/bin/node
  ln -snf "${PREFIX}/bin/npm"  /usr/local/bin/npm
  ln -snf "${PREFIX}/bin/npx"  /usr/local/bin/npx

  cat >/etc/profile.d/node22.sh <<EOF
# Node.js v${NODE_VER}
export PATH="${PREFIX}/bin:\$PATH"
EOF
  chmod 644 /etc/profile.d/node22.sh

  log "Installed:"
  "${PREFIX}/bin/node" -v
  "${PREFIX}/bin/npm" -v
}

main(){
  require_root
  detect_el7
  ensure_swap
  install_prereqs
  enable_toolchains
  prepare_sources
  patch_cares_el7
  configure_build
  build_and_install
  log "Done. New shells will pick up PATH from /etc/profile.d/node22.sh"
  log "If you still hit OOM, rerun with: CXXFLAGS_OLEVEL=0 bash $0"
}

main "$@"
