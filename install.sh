#!/usr/bin/env bash
set -euo pipefail

echo "[Shake&Tune] Installing Debian scientific stack via apt (no atlas, no compile)..."
sudo apt-get update
sudo apt-get install -y python3-venv python3-numpy python3-scipy python3-matplotlib

VENV_DIR="${HOME}/shaketune-venv"
if [ ! -d "${VENV_DIR}" ]; then
  python3 -m venv "${VENV_DIR}"
fi
# shellcheck disable=SC1090
source "${VENV_DIR}/bin/activate"
pip install --upgrade pip wheel setuptools

# Install Python deps, but *exclude* numpy/scipy/matplotlib (provided by apt)
if [ -f requirements.txt ]; then
  if grep -qiE '^(numpy|scipy|matplotlib)(\b|[<=>])' requirements.txt; then
    echo "[Shake&Tune] Filtering numpy/scipy/matplotlib from requirements.txt (using apt packages instead)"
    grep -viE '^(numpy|scipy|matplotlib)(\b|[<=>])' requirements.txt > /tmp/requirements.filtered.txt || true
    # Only install if there are remaining lines
    if [ -s /tmp/requirements.filtered.txt ]; then
      pip install -r /tmp/requirements.filtered.txt
    else
      echo "[Shake&Tune] No additional pip requirements needed."
    fi
  else
    pip install -r requirements.txt
  fi
else
  echo "[Shake&Tune] No requirements.txt found—skipping pip package install."
fi

python - <<'PY'
import numpy, scipy, matplotlib
print("OK: NumPy", numpy.__version__, "| SciPy", scipy.__version__, "| Matplotlib", matplotlib.__version__)
PY

echo "[Shake&Tune] Installed (apt-backed scientific stack on Debian/trixie)."
