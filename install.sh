#!/usr/bin/env bash
# Run from any directory: sudo bash /path/to/cloned/repo/install.sh
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo 'Run with sudo bash install.sh' >&2; exit 1; }
SOURCE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
TARGET=/opt/feeder
STAGE=/opt/feeder.staging
PREVIOUS=/opt/feeder.previous
UNIT=/etc/systemd/system/feeder.service

# Serialize deployments, including cleanup.
exec 9>/run/lock/feeder-install.lock
flock -n 9 || { echo 'Another Feeder installation is running.' >&2; exit 1; }

for path in "$TARGET" "$STAGE" "$PREVIOUS"; do
    [[ "$SOURCE/" != "$path/"* ]] || {
        echo 'Run this installer from your cloned repository outside /opt/feeder*.' >&2
        exit 1
    }
    [[ ! -L "$path" ]] || { echo "Refusing symlink: $path" >&2; exit 1; }
done
for file in feeder.py pyproject.toml templates/index.html static/app.css static/app.js; do
    [[ -f "$SOURCE/$file" ]] || { echo "Missing: $SOURCE/$file" >&2; exit 1; }
done

# Current Raspberry Pi OS (64-bit), with distro Python 3.11+.
python3 -c 'import sys; assert sys.version_info >= (3, 11), "Installer requires Python 3.11+"'
[[ $(dpkg --print-architecture) == arm64 ]] || {
    echo 'This installer targets 64-bit Raspberry Pi OS (arm64).' >&2; exit 1;
}

apt-get update
apt-get install -y python3-venv python3-lgpio v4l-utils curl rsync libgl1 libglib2.0-0
getent group gpio >/dev/null
getent group video >/dev/null
if ! id feeder >/dev/null 2>&1; then
    useradd --system --user-group --home-dir /var/lib/feeder --create-home \
        --shell /usr/sbin/nologin feeder
fi
usermod -aG gpio,video feeder

# These are deployment-owned folders, never the Git checkout.
rm -rf -- "$STAGE"
mkdir -p "$STAGE"
cp -- "$SOURCE/feeder.py" "$SOURCE/pyproject.toml" "$STAGE/"
rsync -rL -- "$SOURCE/templates/" "$STAGE/templates/"
rsync -rL -- "$SOURCE/static/" "$STAGE/static/"

# Use apt's lgpio backend; install the declared application dependencies with pip.
python3 -m venv --system-site-packages "$STAGE/.venv"
"$STAGE/.venv/bin/python" -m pip install --upgrade pip
python3 - "$STAGE/pyproject.toml" "$STAGE/requirements.deploy.txt" <<'PY'
import pathlib
import sys
import tomllib
project = tomllib.loads(pathlib.Path(sys.argv[1]).read_text())["project"]
deps = project.get("dependencies", [])
pathlib.Path(sys.argv[2]).write_text("\n".join([*deps, "gunicorn"]) + "\n")
PY
# Fail rather than spend hours compiling OpenCV if no compatible wheel exists.
"$STAGE/.venv/bin/python" -m pip install --only-binary=opencv-python \
    -r "$STAGE/requirements.deploy.txt"
"$STAGE/.venv/bin/python" -c 'import cv2, flask, gpiozero, lgpio, gunicorn'
"$STAGE/.venv/bin/python" -m py_compile "$STAGE/feeder.py"
chown -R root:root "$STAGE"
chmod -R a+rX "$STAGE"

# New deployment is prepared. Stop and remove the old unit before replacing it.
systemctl stop feeder.service 2>/dev/null || true
systemctl disable feeder.service 2>/dev/null || true
rm -f -- "$UNIT"
systemctl daemon-reload
rm -rf -- "$PREVIOUS"
if [[ -d "$TARGET" ]]; then
    mv -- "$TARGET" "$PREVIOUS"
fi
mv -- "$STAGE" "$TARGET"

# Use python -m, so relocating the staged venv doesn't use stale script shebangs.
cat > "$UNIT" <<'UNIT'
[Unit]
Description=Feeder Shapeoko feedhold controller
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=feeder
Group=feeder
SupplementaryGroups=gpio video
WorkingDirectory=/opt/feeder
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONDONTWRITEBYTECODE=1
Environment=GPIOZERO_PIN_FACTORY=lgpio
StateDirectory=feeder
ExecStart=/opt/feeder/.venv/bin/python -m gunicorn --workers 1 --threads 4 --bind 127.0.0.1:8000 --access-logfile - --error-logfile - feeder:app
Restart=on-failure
RestartSec=5
TimeoutStopSec=10
UMask=0027

[Install]
WantedBy=multi-user.target
UNIT
chmod 644 "$UNIT"
systemctl daemon-reload
systemctl reset-failed feeder.service 2>/dev/null || true
systemctl enable --now feeder.service

# Check actual HTML delivery, without activating any relay.
for attempt in {1..20}; do
    if systemctl is-active --quiet feeder.service && \
        curl --fail --silent --max-time 2 http://127.0.0.1:8000/ >/dev/null; then
        echo 'Feeder deployed successfully at http://127.0.0.1:8000'
        echo 'Logs: journalctl -u feeder -f'
        echo 'Previous deployment retained at /opt/feeder.previous until next install.'
        exit 0
    fi
    sleep 1
done
journalctl -u feeder.service -n 40 --no-pager
echo 'Deployment did not pass its startup check; see logs above.' >&2
exit 1
