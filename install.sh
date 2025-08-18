#!/usr/bin/env bash
# Node.js v22.18.0 build/install script for CentOS 7 / cPanel
# - Uses devtoolset-11 (GCC 11) + rh-python38 (Python 3.8)
# - Downloads RPMs from CentOS Vault (no EOL repos required)
# - Patches c-ares config to avoid sys/random.h on glibc 2.17
# - Installs into /opt/nodejs/node-v22 and adds /etc/profile.d shim

set -Eeuo pipefail

### --- CONFIG (tweak if you like) ---
NODE_VERSION="22.18.0"
NODE_VER="v${NODE_VERSION}"
NODE_PREFIX="/opt/nodejs/node-v22"
BUILD_DIR="/usr/local/src"
WORK_RPM_DIR="/root/dts11"
MAKE_JOBS="$(nproc 2>/dev/null || echo 2)"
NICE_BUILD=1

CENTOS_VAULT_BASE="https://vault.centos.org/7.9.2009/sclo/x86_64/rh/Packages"
PY38_BIN="/opt/rh/rh-python38/root/usr/bin/python3"
DTS_ENABLE="/opt/rh/devtoolset-11/enable"
PROFILE_SH="/etc/profile.d/node-v22.sh"
### ----------------------------------

log() { printf "\n\033[1;32m[+] %s\033[0m\n" "$*"; }
warn(){ printf "\n\033[1;33m[!] %s\033[0m\n" "$*"; }
die() { printf "\n\033[1;31m[x] %s\033[0m\n" "$*"; exit 1; }

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root."
}

assert_env() {
  [[ -f /etc/os-release ]] || die "/etc/os-release not found."
  grep -qE '^VERSION_ID="7"' /etc/os-release || die "This script targets CentOS 7."
  [[ "$(uname -m)" == "x86_64" ]] || die "x86_64 only."
  command -v curl >/dev/null 2>&1 || die "curl is required."
}

prep_dirs() {
  log "Preparing directories"
  rm -rf "$NODE_PREFIX"
  mkdir -p "$NODE_PREFIX" "$BUILD_DIR" "$WORK_RPM_DIR"
}

grab_latest() {
  local dir="$1" pattern="$2"
  # shellcheck disable=SC2086
  local file
  file="$(curl -fsSL "$dir/" | grep -oE "$pattern" | sort -V | tail -1 || true)"
  [[ -n "$file" ]] || die "Could not find $pattern in $dir"
  curl -fsSLO "$dir/$file"
}

download_dts11_rpms() {
  log "Fetching devtoolset-11 RPMs from CentOS Vault"
  cd "$WORK_RPM_DIR"
  grab_latest "$CENTOS_VAULT_BASE/d" 'devtoolset-11-runtime-[0-9][^"]*\.rpm'
  grab_latest "$CENTOS_VAULT_BASE/d" 'devtoolset-11-build-[0-9][^"]*\.rpm'
  grab_latest "$CENTOS_VAULT_BASE/d" 'devtoolset-11-gcc-[0-9][^"]*\.rpm'
  grab_latest "$CENTOS_VAULT_BASE/d" 'devtoolset-11-gcc-c\+\+-[0-9][^"]*\.rpm'
  grab_latest "$CENTOS_VAULT_BASE/d" 'devtoolset-11-binutils-[0-9][^"]*\.rpm'
  grab_latest "$CENTOS_VAULT_BASE/d" 'devtoolset-11-libstdc\+\+-devel-[0-9][^"]*\.rpm'
  grab_latest "$CENTOS_VAULT_BASE/d" 'devtoolset-11-libgccjit-[0-9][^"]*\.rpm'
  # Clean any old base "devtoolset-11-*.el7.x86_64.rpm" root metapackages we don't install
  rm -f 'devtoolset-11-[0-9]*.el7.x86_64.rpm' || true
}

download_rhpython38_rpms() {
  log "Fetching rh-python38 RPMs from CentOS Vault"
  cd "$WORK_RPM_DIR"
  grab_latest "$CENTOS_VAULT_BASE/r" 'rh-python38-runtime-[0-9][^"]*\.rpm'
  grab_latest "$CENTOS_VAULT_BASE/r" 'rh-python38-python-[0-9][^"]*\.rpm'
  grab_latest "$CENTOS_VAULT_BASE/r" 'rh-python38-python-libs-[0-9][^"]*\.rpm'
  grab_latest "$CENTOS_VAULT_BASE/r" 'rh-python38-python-devel-[0-9][^"]*\.rpm'
  grab_latest "$CENTOS_VAULT_BASE/r" 'rh-python38-python-pip-[0-9][^"]*\.rpm'
  grab_latest "$CENTOS_VAULT_BASE/r" 'rh-python38-python-setuptools-[0-9][^"]*\.rpm'
  grab_latest "$CENTOS_VAULT_BASE/r" 'rh-python38-python-wheel-[0-9][^"]*\.rpm'
  # Extra wheels + macros that yum complains about if missing
  grab_latest "$CENTOS_VAULT_BASE/r" 'rh-python38-python-pip-wheel-[0-9][^"]*\.rpm'
  grab_latest "$CENTOS_VAULT_BASE/r" 'rh-python38-python-setuptools-wheel-[0-9][^"]*\.rpm'
  grab_latest "$CENTOS_VAULT_BASE/r" 'rh-python38-python-rpm-macros-[0-9][^"]*\.rpm'
}

install_prereqs() {
  log "Installing base prerequisites from system repos"
  yum install -y -q \
    scl-utils scl-utils-build redhat-rpm-config \
    iso-codes dwz perl-srpm-macros xml-common \
    python3 git xz make gcc gcc-c++ perl pkgconfig || true
}

install_dts11_locally() {
  log "Installing devtoolset-11 locally"
  cd "$WORK_RPM_DIR"
  yum localinstall -y -q ./*devtoolset-11-*.rpm || true
  [[ -f "$DTS_ENABLE" ]] || die "devtoolset-11 enable script not found at $DTS_ENABLE"
}

install_rhpython38_locally() {
  log "Installing rh-python38 locally"
  cd "$WORK_RPM_DIR"
  yum localinstall -y -q \
    ./rh-python38-python-*.rpm \
    ./rh-python38-python-libs-*.rpm \
    ./rh-python38-python-devel-*.rpm \
    ./rh-python38-runtime-*.rpm \
    ./rh-python38-python-wheel-*.rpm \
    ./rh-python38-python-pip-*.rpm \
    ./rh-python38-python-pip-wheel-*.rpm \
    ./rh-python38-python-setuptools-*.rpm \
    ./rh-python38-python-setuptools-wheel-*.rpm \
    ./rh-python38-python-rpm-macros-*.rpm
  [[ -x "$PY38_BIN" ]] || die "Python 3.8 binary not found at $PY38_BIN"
}

fetch_node_source() {
  log "Downloading Node.js $NODE_VER source"
  cd "$BUILD_DIR"
  rm -rf "node-$NODE_VER" "node-$NODE_VER.tar.xz" || true
  curl -fsSLO "https://nodejs.org/dist/${NODE_VER}/node-${NODE_VER}.tar.xz"
  tar -xJf "node-${NODE_VER}.tar.xz"
}

patch_cares_for_el7() {
  # On CentOS 7 (glibc 2.17) c-ares config claims sys/random.h + getrandom(),
  # causing: fatal error: sys/random.h: No such file or directory
  local cfg="${BUILD_DIR}/node-${NODE_VER}/deps/cares/config/linux/ares_config.h"
  if [[ ! -f "$cfg" ]]; then
    die "c-ares config header not found: $cfg"
  fi
  log "Patching c-ares config to disable sys/random.h/getrandom for EL7"
  if grep -qE '^[[:space:]]*#define[[:space:]]+HAVE_SYS_RANDOM_H' "$cfg"; then
    sed -ri 's/^[[:space:]]*#define[[:space:]]+HAVE_SYS_RANDOM_H.*/#undef HAVE_SYS_RANDOM_H/' "$cfg"
  elif ! grep -q '^#undef HAVE_SYS_RANDOM_H' "$cfg"; then
    echo '#undef HAVE_SYS_RANDOM_H' >> "$cfg"
  fi
  if grep -qE '^[[:space:]]*#define[[:space:]]+HAVE_GETRANDOM' "$cfg"; then
    sed -ri 's/^[[:space:]]*#define[[:space:]]+HAVE_GETRANDOM.*/#undef HAVE_GETRANDOM/' "$cfg"
  elif ! grep -q '^#undef HAVE_GETRANDOM' "$cfg"; then
    echo '#undef HAVE_GETRANDOM' >> "$cfg"
  fi
  grep -nE 'HAVE_SYS_RANDOM_H|HAVE_GETRANDOM' "$cfg" || true
}

configure_and_build_node() {
  log "Enabling devtoolset-11 toolchain"
  # shellcheck source=/dev/null
  source "$DTS_ENABLE"
  gcc --version | head -n1

  log "Configuring Node build with Python 3.8: $PY38_BIN"
  export PATH="/opt/rh/rh-python38/root/usr/bin:$PATH"
  export PYTHON="$PY38_BIN"

  cd "${BUILD_DIR}/node-${NODE_VER}"

  # Clean any prior out/objects just in case of re-run
  rm -rf out || true

  ./configure --prefix="$NODE_PREFIX" PYTHON="$PY38_BIN"

  log "Building Node.js (jobs: $MAKE_JOBS)"
  if [[ $NICE_BUILD -eq 1 ]]; then
    nice -n 10 make -j"$MAKE_JOBS"
  else
    make -j"$MAKE_JOBS"
  fi

  log "Installing to $NODE_PREFIX"
  make install
}

install_profile_shim() {
  log "Creating $PROFILE_SH"
  cat > "$PROFILE_SH" <<EOF
# Added by install-node22.sh
export PATH="${NODE_PREFIX}/bin:\$PATH"
EOF
  chmod 0644 "$PROFILE_SH"
}

verify_install() {
  log "Verifying installation"
  export PATH="${NODE_PREFIX}/bin:$PATH"
  node -v
  npm -v
  which node
}

main() {
  require_root
  assert_env
  prep_dirs
  download_dts11_rpms
  download_rhpython38_rpms
  install_prereqs
  install_dts11_locally
  install_rhpython38_locally
  fetch_node_source
  patch_cares_for_el7
  configure_and_build_node
  install_profile_shim
  verify_install
  log "Done. Open a new shell or 'source $PROFILE_SH' to use node/npm globally."
}

main "$@"
