#!/usr/bin/env bash
# Option A (apt-only) installer for Shake&Tune on Debian 13 (trixie)
# - No ATLAS
# - Uses apt prebuilt numpy/scipy/matplotlib
# - Lets Klipper venv see system packages via .pth
set -euo pipefail
export LC_ALL=C

USER_CONFIG_PATH="${HOME}/printer_data/config"
MOONRAKER_CONFIG="${HOME}/printer_data/config/moonraker.conf"
KLIPPER_PATH="${HOME}/klipper"
KLIPPER_VENV_PATH="${KLIPPER_VENV:-${HOME}/klippy-env}"   # Klipper venv
K_SHAKETUNE_PATH="${HOME}/klippain_shaketune"

# ---- preflight (same flow as upstream) ----
preflight_checks() {
  if [ "$EUID" -eq 0 ]; then
    echo "[PRE-CHECK] This script must not be run as root!"
    exit 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "[ERROR] Python 3 is not installed. Please install Python 3!"
    exit 1
  fi
  if systemctl list-units --full -all -t service --no-legend | grep -F 'klipper.service'; then
    printf "[PRE-CHECK] Klipper service found! Continuing...\n\n"
  else
    echo "[ERROR] Klipper service not found. Install Klipper first!"
    exit 1
  fi
  install_package_requirements
}

# ---- apt deps (Option A) ----
is_package_installed() { dpkg -s "$1" >/dev/null 2>&1; }

install_package_requirements() {
  local packages=(python3-venv python3-numpy python3-scipy python3-matplotlib)
  local to_install=()
  for p in "${packages[@]}"; do
    if is_package_installed "$p"; then
      echo "$p is already installed"
    else
      to_install+=("$p")
    fi
  done
  if [ "${#to_install[@]}" -gt 0 ]; then
    echo "Installing missing packages: ${to_install[*]}"
    sudo apt update
    sudo apt install -y "${to_install[@]}"
  fi
}

# ---- fetch / update repo (same as upstream, but use your fork) ----
check_download() {
  if [ ! -d "${K_SHAKETUNE_PATH}" ]; then
    echo "[DOWNLOAD] Cloning Klippain Shake&Tune (your fork)..."
    git clone https://github.com/Wondro/klippain-shaketune.git "${K_SHAKETUNE_PATH}"
    chmod +x "${K_SHAKETUNE_PATH}/install.sh"
    printf "[DOWNLOAD] Download complete!\n\n"
  else
    printf "[DOWNLOAD] Repo already present. Updating...\n"
    git -C "${K_SHAKETUNE_PATH}" fetch --all -p
    git -C "${K_SHAKETUNE_PATH}" checkout main
    git -C "${K_SHAKETUNE_PATH}" pull --ff-only
    printf "[DOWNLOAD] Update complete!\n\n"
  fi
}

# ---- venv setup: use apt stack inside venv via .pth; filter heavy wheels from pip ----
setup_venv() {
  if [ ! -d "${KLIPPER_VENV_PATH}" ]; then
    echo "[ERROR] Klipper's Python virtual environment not found at ${KLIPPER_VENV_PATH}!"
    exit 1
  fi

  # Activate Klipper venv
  # shellcheck disable=SC1090
  source "${KLIPPER_VENV_PATH}/bin/activate"

  echo "[SETUP] Ensuring venv can see system site-packages (apt numpy/scipy/matplotlib)..."
  # Write a .pth to include Debian's dist-packages in this venv
  local vsp
  vsp="$("${KLIPPER_VENV_PATH}/bin/python" - <<'PY'
import sysconfig, sys
# Typical Debian path:
print("/usr/lib/python3/dist-packages")
PY
)"
  local site_dir
  site_dir="$("${KLIPPER_VENV_PATH}/bin/python" - <<'PY'
import site
print(site.getsitepackages()[0])
PY
)"
  mkdir -p "${site_dir}"
  echo "import site; site.addsitedir('${vsp}')" > "${site_dir}/_system_site.pth"

  echo "[SETUP] Installing/updating Shake&Tune Python deps (excluding numpy/scipy/matplotlib)..."
  pip install --upgrade pip wheel setuptools

  if [ -f "${K_SHAKETUNE_PATH}/requirements.txt" ]; then
    if grep -qiE '^(numpy|scipy|matplotlib)(\b|[<=>])' "${K_SHAKETUNE_PATH}/requirements.txt"; then
      echo "[SETUP] Filtering numpy/scipy/matplotlib from requirements.txt"
      grep -viE '^(numpy|scipy|matplotlib)(\b|[<=>])' "${K_SHAKETUNE_PATH}/requirements.txt" > /tmp/requirements.filtered.txt || true
      if [ -s /tmp/requirements.filtered.txt ]; then
        pip install -r /tmp/requirements.filtered.txt
      else
        echo "[SETUP] No additional pip requirements."
      fi
    else
      pip install -r "${K_SHAKETUNE_PATH}/requirements.txt"
    fi
  else
    echo "[SETUP] No requirements.txt found—skipping pip package install."
  fi

  # Quick import sanity check
  python - <<'PY'
import numpy, scipy, matplotlib
print("OK: NumPy", numpy.__version__, "| SciPy", scipy.__version__, "| Matplotlib", matplotlib.__version__)
PY

  deactivate
  printf "\n"
}

# ---- keep old extension cleanup logic (same as upstream) ----
link_extension() {
  if [ -d "${HOME}/klippain_config" ] && [ -f "${USER_CONFIG_PATH}/.VERSION" ]; then
    if [ -d "${USER_CONFIG_PATH}/scripts/K-ShakeTune" ]; then
      echo "[INFO] Old K-Shake&Tune macro folder found, cleaning it!"
      rm -d "${USER_CONFIG_PATH}/scripts/K-ShakeTune"
    fi
  else
    if [ -d "${USER_CONFIG_PATH}/K-ShakeTune" ]; then
      echo "[INFO] Old K-Shake&Tune macro folder found, cleaning it!"
      rm -d "${USER_CONFIG_PATH}/K-ShakeTune"
    fi
  fi
}

# ---- link module into Klipper (same as upstream) ----
link_module() {
  if [ ! -d "${KLIPPER_PATH}/klippy/extras/shaketune" ]; then
    echo "[INSTALL] Linking Shake&Tune module to Klipper extras"
    ln -frsn "${K_SHAKETUNE_PATH}/shaketune" "${KLIPPER_PATH}/klippy/extras/shaketune"
  else
    printf "[INSTALL] Klippain Shake&Tune Klipper module is already installed.\n\n"
  fi
}

# ---- add Moonraker updater (points to your fork) ----
add_updater() {
  local update_section
  update_section=$(grep -c '\[update_manager[a-z ]* Klippain-ShakeTune\]' "$MOONRAKER_CONFIG" || true)
  if [ "$update_section" -eq 0 ]; then
    echo -n "[INSTALL] Adding update manager to moonraker.conf..."
    cat <<EOF >>"$MOONRAKER_CONFIG"

## Klippain Shake&Tune automatic update management
[update_manager Klippain-ShakeTune]
type: git_repo
origin: https://github.com/Wondro/klippain-shaketune.git
path: ~/klippain_shaketune
virtualenv: ${KLIPPER_VENV_PATH}
requirements: requirements.txt
system_dependencies: system-dependencies.json
primary_branch: main
managed_services: klipper
EOF
    echo " done."
  fi
}

restart_klipper()  { echo "[POST-INSTALL] Restarting Klipper...";   sudo systemctl restart klipper; }
restart_moonraker(){ echo "[POST-INSTALL] Restarting Moonraker..."; sudo systemctl restart moonraker; }

printf "\n=============================================\n"
echo   "- Klippain Shake&Tune module install script -"
printf "=============================================\n\n"

preflight_checks
check_download
setup_venv
link_extension
link_module
add_updater
restart_klipper
restart_moonraker
