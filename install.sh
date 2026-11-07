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
WorkingDirectory=/var/lib/feeder
Environment=PYTHONPATH=/opt/feeder
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
