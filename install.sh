#!/bin/bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo 'Run with: sudo bash install.sh'
    exit 1
fi

SOURCE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TARGET=/opt/feeder

# Check source files before stopping or deleting anything.
for file in feeder.py pyproject.toml templates/index.html static/app.css static/app.js; do
    [[ -f "$SOURCE/$file" ]] || { echo "Missing: $SOURCE/$file"; exit 1; }
done
[[ "$SOURCE" != /opt/feeder && "$SOURCE" != /opt/feeder/* ]] || {
    echo 'Run this from the cloned repository, outside /opt/feeder.'; exit 1;
}
[[ ! -L "$TARGET" ]] || { echo 'Refusing to replace a symlink at /opt/feeder.'; exit 1; }
python3 -c 'import tomllib' || { echo 'Python 3.11+ is required.'; exit 1; }

echo '[1/6] Stopping existing service'
systemctl stop feeder.service 2>/dev/null || true
systemctl disable feeder.service 2>/dev/null || true
rm -f /etc/systemd/system/feeder.service
systemctl daemon-reload

echo '[2/6] Installing system dependencies'
apt-get update
apt-get install -y --no-install-recommends python3-venv python3-lgpio

echo '[3/6] Preparing service user'
id feeder >/dev/null 2>&1 || useradd --system --user-group --no-create-home --shell /usr/sbin/nologin feeder
usermod -aG gpio,video feeder

echo '[4/6] Replacing application files in /opt/feeder'
rm -rf -- "$TARGET"
mkdir -p "$TARGET"
cp -- "$SOURCE/feeder.py" "$SOURCE/pyproject.toml" "$TARGET/"
cp -rL -- "$SOURCE/templates" "$SOURCE/static" "$TARGET/"

echo '[5/6] Installing Python dependencies'
python3 -m venv --system-site-packages "$TARGET/.venv"
python3 - "$TARGET" <<'PY'
import pathlib
import tomllib
import sys
root = pathlib.Path(sys.argv[1])
deps = tomllib.loads((root / 'pyproject.toml').read_text())['project']['dependencies']
(root / 'requirements.deploy.txt').write_text('\n'.join([*deps, 'gunicorn']) + '\n')
PY
"$TARGET/.venv/bin/python" -m pip install \
    --only-binary=opencv-python,opencv-python-headless \
    -r "$TARGET/requirements.deploy.txt"
chmod -R a+rX "$TARGET"

echo '[6/6] Installing and starting service'
cat > /etc/systemd/system/feeder.service <<'UNIT'
[Unit]
Description=Feeder CNC feedhold controller
After=network.target

[Service]
User=feeder
SupplementaryGroups=gpio video
StateDirectory=feeder
WorkingDirectory=/var/lib/feeder
Environment=PYTHONPATH=/opt/feeder
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONDONTWRITEBYTECODE=1
Environment=GPIOZERO_PIN_FACTORY=lgpio
ExecStart=/opt/feeder/.venv/bin/python -m gunicorn --workers 1 --threads 4 --bind 127.0.0.1:8000 --access-logfile - --error-logfile - feeder:app
Restart=on-failure
RestartSec=5
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl reset-failed feeder.service 2>/dev/null || true
systemctl enable --now feeder.service

echo 'Installation complete; service start requested.'
echo 'View logs: journalctl -u feeder -f'
