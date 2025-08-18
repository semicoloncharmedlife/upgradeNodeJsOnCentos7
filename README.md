# Node.js 22.18.0 Build & Install Script for CentOS 7 with cPanel

This README documents a Bash script that **builds and installs Node.js v22.18.0 on CentOS 7 (x86_64) with cPanel**. It targets legacy servers that need **modern Node.js 22.x** without enabling EOL repos. The script pulls **devtoolset-11 (GCC 11)** and **rh-python38 (Python 3.8)** from the **CentOS Vault**, **patches c-ares** to avoid `sys/random.h`/`getrandom()` on **glibc 2.17**, compiles Node.js from source, installs to `/opt/nodejs/node-v22`, and adds a global PATH shim via `/etc/profile.d/node-v22.sh`.

---

## Why this exists (SEO-focused overview)

- Install Node.js 22 on CentOS 7 with cPanel  
- Build Node.js from source on legacy CentOS 7 servers  
- Fix Node.js build failures on glibc 2.17 using c-ares patch  
- Use devtoolset-11 GCC 11 toolchain for Node.js 22.x builds  
- Enable Python 3.8 (rh-python38) for Node/GYP compatibility  
- Deploy Node.js and npm on cPanel without EOL repos  
- CentOS Vault RPMs for devtoolset-11 and rh-python38  
- Production-friendly, reproducible Node.js builds on older infrastructure

---

## What the script does (detailed)

1) Validates environment  
   - Requires root.  
   - Ensures `/etc/os-release` exists, `VERSION_ID="7"`, and architecture is `x86_64`.  
   - Verifies `curl` presence.

2) Prepares directories  
   - Removes any previous install at `/opt/nodejs/node-v22`.  
   - Creates install prefix `/opt/nodejs/node-v22`, build dir `/usr/local/src`, and working RPM dir `/root/dts11`.

3) Downloads required RPMs from CentOS Vault  
   - **devtoolset-11**: runtime, build, gcc, gcc-c++, binutils, libstdc++-devel, libgccjit (from `https://vault.centos.org/7.9.2009/sclo/x86_64/rh/Packages/d`).  
   - **rh-python38**: runtime, python, libs, devel, pip, setuptools, wheel, plus `*-wheel` and `*-rpm-macros` support packages (from `.../Packages/r`).  
   - Uses a `grab_latest` helper that scrapes directory indexes and fetches the newest matching RPM filenames, ensuring you always get the latest Vault builds for EL7.

4) Installs base prerequisites from system repos  
   - Installs `scl-utils`, `scl-utils-build`, `redhat-rpm-config`, `iso-codes`, `dwz`, `perl-srpm-macros`, `xml-common`, `python3`, `git`, `xz`, `make`, `gcc`, `gcc-c++`, `perl`, `pkgconfig`.  
   - These support both the toolchain and various configure/build steps.

5) Local-installs devtoolset-11 and rh-python38 (no EOL repo enable)  
   - Uses `yum localinstall -y -q` on the fetched RPMs from the working directory.  
   - Verifies the devtoolset enable script at `/opt/rh/devtoolset-11/enable`.  
   - Verifies Python 3.8 binary at `/opt/rh/rh-python38/root/usr/bin/python3`.

6) Fetches Node.js source and extracts  
   - Downloads `https://nodejs.org/dist/v22.18.0/node-v22.18.0.tar.xz` to `/usr/local/src` and extracts it.

7) Patches c-ares for EL7 glibc 2.17  
   - Edits `deps/cares/config/linux/ares_config.h` to `#undef HAVE_SYS_RANDOM_H` and `#undef HAVE_GETRANDOM` if needed.  
   - This avoids compile-time failures referencing headers/symbols missing in glibc 2.17.

8) Configures and builds Node.js with GCC 11 and Python 3.8  
   - `source /opt/rh/devtoolset-11/enable` to activate GCC 11.  
   - Exports `PYTHON=/opt/rh/rh-python38/root/usr/bin/python3` and ensures it’s on PATH.  
   - Runs `./configure --prefix=/opt/nodejs/node-v22`.  
   - Builds with `make -j$(nproc)` (nice’d by default) and installs with `make install`.

9) Adds a global PATH shim  
   - Writes `/etc/profile.d/node-v22.sh` to prepend `/opt/nodejs/node-v22/bin` to PATH for all users.  
   - This exposes `node`, `npm`, and `npx` in new shells without manual exports.

10) Verifies the installation  
   - Runs `node -v`, `npm -v`, and prints `which node`.  
   - Prompts you to open a new shell or `source /etc/profile.d/node-v22.sh`.

---

## Configuration knobs (top-of-file variables)

- `NODE_VERSION="22.18.0"` and `NODE_VER="v${NODE_VERSION}"`  
- `NODE_PREFIX="/opt/nodejs/node-v22"` (install destination)  
- `BUILD_DIR="/usr/local/src"`  
- `WORK_RPM_DIR="/root/dts11"`  
- `MAKE_JOBS="$(nproc || echo 2)"` (parallel build)  
- `NICE_BUILD=1` (lower CPU priority during make)  
- `CENTOS_VAULT_BASE="https://vault.centos.org/7.9.2009/sclo/x86_64/rh/Packages"`  
- `PY38_BIN="/opt/rh/rh-python38/root/usr/bin/python3"`  
- `DTS_ENABLE="/opt/rh/devtoolset-11/enable"`  
- `PROFILE_SH="/etc/profile.d/node-v22.sh"`

You can change `NODE_PREFIX` if you prefer a different install path (e.g., `/usr/local/node-v22`). If you modify paths, ensure the `PROFILE_SH` shim matches.

---

## Usage

Prereqs: run as root on CentOS 7 x86_64 with network access.

1) Save the installer script (for example as `/root/install-node22.sh`) and make it executable  
    chmod +x /root/install-node22.sh

2) Execute the installer  
    /root/install-node22.sh

3) Start a new shell session or source the profile shim  
    source /etc/profile.d/node-v22.sh

4) Verify tools  
    node -v  
    npm -v  
    which node

---

## cPanel considerations

- Installing into `/opt/nodejs/node-v22` avoids conflicts with cPanel-managed system packages.  
- The `/etc/profile.d` shim ensures interactive shells and most service users inherit the Node.js 22 toolchain.  
- For cPanel app deployments or user shells, confirm that login profiles load `/etc/profile.d/*.sh`. If not, explicitly export PATH or symlink `node` into a path already in users’ environment.

---

## Troubleshooting (common EL7/Node 22 issues)

- Build fails with Python/GYP errors  
  - Ensure `PY38_BIN` exists and `PYTHON` env var points to it. The script exports `PYTHON` before configuring.  
  - Check that `rh-python38` RPMs were successfully installed via `yum localinstall`.

- `fatal error: sys/random.h: No such file or directory` or unresolved `getrandom`  
  - Confirm the c-ares header edits were applied in `deps/cares/config/linux/ares_config.h`.  
  - Re-run the script; it prints the `grep` lines it changed.

- `gcc: command not found` or old GCC used  
  - Verify `source /opt/rh/devtoolset-11/enable` occurs in the build step (the script does this for you).  
  - Ensure devtoolset RPMs installed successfully from the Vault.

- `yum` dependency resolution failures  
  - The script downloads all needed SCL RPMs locally. If your mirror is slow or blocked, re-run later or ensure outbound network access to `vault.centos.org`.

- Proxy/SSL inspection environments  
  - Set `http_proxy`/`https_proxy` as required before running the script so `curl` and `yum` can reach external endpoints.

- SELinux  
  - Typical builds succeed under default SELinux. If your policy is strict, consider permissive mode for the duration of the build and revert afterward.

---

## Security and operations notes

- Run only as root on trusted hosts. Review the script prior to execution.  
- The install lives under `/opt/nodejs/node-v22`; upgrades can be handled by installing to a new directory (e.g., `/opt/nodejs/node-v22.19`) and updating the profile shim.  
- Keep a rollback plan (retain previous Node directories or package your builds as tarballs).

---

## Uninstall / rollback

- Remove the PATH shim  
    rm -f /etc/profile.d/node-v22.sh

- Remove the install directory (ensure you’re removing the correct tree)  
    rm -rf /opt/nodejs/node-v22

- Open a new shell or reload environment; `node -v` should no longer report v22.

---

## FAQ

Q: Why not use `yum install nodejs` on CentOS 7?  
A: EL7 repos provide very old Node releases (if any). Node 22 requires a newer toolchain and Python than stock EL7 provides. This script supplies both via CentOS Vault SCL RPMs and builds from source.

Q: Can I change the Node version?  
A: Yes. Set `NODE_VERSION` and `NODE_VER` consistently (e.g., `NODE_VERSION="22.19.0"` / `NODE_VER="v22.19.0"`). Make sure the version exists at `https://nodejs.org/dist/`.

Q: Will this affect system Python or GCC?  
A: No. devtoolset-11 and rh-python38 are **Software Collections** installed in parallel; they’re enabled only for the build step. The runtime Node.js does not depend on them after installation.

Q: Does this work on Alma/Rocky/Stream?  
A: This script explicitly targets CentOS 7 with SCL Vault RPM locations. For other distributions, adapt the RPM sources and OS checks.

---

## At-a-glance keywords (SEO)

Install Node 22 on CentOS 7, Node.js 22.18.0 CentOS 7, cPanel Node.js install, build Node.js from source EL7, GCC 11 devtoolset-11 Node 22, Python 3.8 rh-python38 for Node-GYP, c-ares glibc 2.17 getrandom patch, Node.js npm npx on legacy Linux, CentOS Vault RPMs SCL, production Node.js on cPanel servers.

---

## License

MIT – use, modify, and distribute as needed.
