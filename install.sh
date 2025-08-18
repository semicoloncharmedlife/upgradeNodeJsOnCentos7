#!/usr/bin/env bash
# Build & install Node.js v22.18.0 on EL7/cPanel with c-ares + OOM workarounds.
# - Disables c-ares sys/random.h & getrandom on EL7
# - Uses devtoolset-11 + rh-python38 (SCL)
# - Adds swap on low-RAM systems to avoid "Killed signal" (OOM)
# - Installs to /opt/node-v22.18.0 and exposes via /etc/profile.d

set -euo pipefail

NODE_VER="${NODE_VER:-22.18.0}"
PREFIX="${PREFIX:-/opt/node-v${NODE_VER}}"
SRC_DIR="${SRC_DIR:-/usr/local/src}"
TARBALL="node-v${NODE_VER}.tar.xz"
TARBALL_URL="https://nodejs.org/dist/v${NODE_VER}/${TARBALL}"
BUILD_DIR="${SRC_DIR}/node-v${NODE_VER}"

log(){ printf "[%s] %s\n" "$(date +'%F %T')" "$*" ; }

require_root(){
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Please run as root."; exit 1
  fi
}

detect_el7(){
  if [[ -f /etc/redhat-release ]] && grep -qE 'release 7(\.|$)' /etc/redhat-release; then
    return 0
  fi
  echo "This script targets RHEL/CentOS/CloudLinux 7 only."; exit 1
}

install_prereqs(){
  log "Installing prerequisites (may be no-ops if already present)…"
  yum -y install curl tar xz make perl gcc gcc-c++ python3 || true
  # Enable SCL (CentOS) — harmless if already enabled / not needed
  yum -y install centos-release-scl || true
  # Toolchains we actually use
  yum -y install devtoolset-11 rh-python38 || true
}

enable_toolchains(){
  # Make SCL runtimes active for this shell (needed for proper LD_LIBRARY_PATH etc.)
  if [[ -f /opt/rh/devtoolset-11/enable ]]; then source /opt/rh/devtoolset-11/enable; fi
  if [[ -f /opt/rh/rh-python38/enable ]]; then source /opt/rh/rh-python38/enable; fi

  # Pin Python for gyp
  if [[ -x /opt/rh/rh-python38/root/usr/bin/python3 ]]; then
    export PYTHON=/opt/rh/rh-python38/root/usr/bin/python3
    export GYP_PYTHON="$PYTHON"
  elif command -v python3 >/dev/null 2>&1; then
    export PYTHON="$(command -v python3)"
    export GYP_PYTHON="$PYTHON"
  else
    echo "Python 3 not found; install rh-python38 or python3."; exit 1
  fi

  log "Toolchains enabled:"
  gcc --version | head -n1 || true
  "$PYTHON" --version || true
}

ensure_swap_and_jobs(){
  # Decide swap + parallel jobs based on RAM
  local mem_mb jobs
  mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)

  if (( mem_mb < 6144 )); then
    if ! swapon --show | awk '{print $1}' | grep -q '^/swapfile$'; then
      log "Low RAM (${mem_mb} MiB). Creating 8G swap at /swapfile to avoid OOM…"
      fallocate -l 8G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=8192
      chmod 600 /swapfile
      mkswap /swapfile
      swapon /swapfile
      grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    jobs=1
  else
    jobs=$(nproc)
  fi

  export MAKE_JOBS="${MAKE_JOBS:-$jobs}"
  log "Using MAKE_JOBS=${MAKE_JOBS}"
}

prepare_sources(){
  mkdir -p "$SRC_DIR"
  cd "$SRC_DIR"

  if [[ ! -f "$TARBALL" ]]; then
    log "Downloading Node.js v${NODE_VER} source…"
    curl -fsSLO "$TARBALL_URL"
  else
    log "Source tarball already present: $TARBALL"
  fi

  if [[ -d "$BUILD_DIR" ]]; then
    log "Reusing existing source dir: $BUILD_DIR"
  else
    log "Extracting ${TARBALL}…"
    tar -xf "$TARBALL"
  fi
}

patch_cares_for_el7(){
  # Disable sys/random.h and getrandom in bundled c-ares for EL7
  local cfg="${BUILD_DIR}/deps/cares/config/linux/ares_config.h"
  if [[ -f "$cfg" ]]; then
    log "Patching c-ares ares_config.h to disable sys/random.h & getrandom on EL7…"
    sed -ri 's/^[[:space:]]*#define[[:space:]]+HAVE_SYS_RANDOM_H\b.*/#undef HAVE_SYS_RANDOM_H/' "$cfg" || true
    sed -ri 's/^[[:space:]]*#define[[:space:]]+HAVE_GETRANDOM\b.*/#undef HAVE_GETRANDOM/' "$cfg" || true
    # Show what we have now
    grep -nE 'HAVE_(SYS_RANDOM_H|GETRANDOM)' "$cfg" || true
  else
    log "WARNING: ${cfg} not found. (Node layout changed?) Continuing anyway."
  fi
}

configure_build(){
  cd "$BUILD_DIR"

  # Slightly lighter optimization to save RAM, keep debug symbols off
  export CFLAGS="${CFLAGS:-} -O2 -g0"
  export CXXFLAGS="${CXXFLAGS:-} -O2 -g0"

  log "Configuring Node build (prefix: ${PREFIX}) with Python: ${PYTHON}"
  # Pass PYTHON via env so GYP uses it
  PYTHON="${PYTHON}" ./configure --prefix="${PREFIX}"
}

build_and_install(){
  cd "$BUILD_DIR"
  log "Building Node.js (this takes a while)…"
  make -j"${MAKE_JOBS}"
  log "Installing to ${PREFIX}…"
  make install

  # Global shims
  ln -snf "${PREFIX}/bin/node" /usr/local/bin/node
  ln -snf "${PREFIX}/bin/npm"  /usr/local/bin/npm
  ln -snf "${PREFIX}/bin/npx"  /usr/local/bin/npx

  # Profile.d for interactive shells
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
  install_prereqs
  enable_toolchains
  ensure_swap_and_jobs
  prepare_sources
  patch_cares_for_el7
  configure_build
  build_and_install
  log "Done. New shell sessions will pick up PATH from /etc/profile.d/node22.sh"
}

main "$@"
