#!/bin/bash
#
# setup_jetson_uart.sh
# Fully automates: UART enable, JetsonHacks fix, pyserial, pymavlink/mavproxy,
# dialout group, reboot, and POST-REBOOT self-verification (heartbeat test)
# with zero manual steps other than watching the log after the automatic reboot.
#
# Usage:  chmod +x setup_jetson_uart.sh && ./setup_jetson_uart.sh
#
set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")
LOGFILE="$REAL_HOME/uart_setup.log"
VERIFY_PY="$REAL_HOME/verify_uart_heartbeat.py"
SERVICE_NAME="uart-verify.service"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"; }

log "===== STEP 1: Disable nvgetty ====="
sudo systemctl stop nvgetty 2>/dev/null || true
sudo systemctl disable nvgetty 2>/dev/null || true
sudo systemctl mask nvgetty 2>/dev/null || true

log "===== STEP 2: Clone / update JetsonHacks UART repo ====="
cd "$REAL_HOME"
if [ -d "jetson-orin-uart" ]; then
    rm -rf jetson-orin-uart
fi
git clone https://github.com/jetsonhacks/jetson-orin-uart.git
cd jetson-orin-uart
chmod +x install.sh
log "Running repo install.sh (adds $REAL_USER to dialout, sets udev rules)..."
./install.sh

log "===== STEP 3: Install Python / MAVLink dependencies ====="
sudo apt-get update -y
sudo apt-get install -y python3-serial python3-pip python3-dev libxml2-dev libxslt1-dev
sudo -u "$REAL_USER" pip3 install --user pymavlink mavproxy

log "===== STEP 4: Ensure user is in dialout group ====="
sudo usermod -aG dialout "$REAL_USER"

log "===== STEP 5: Write automated heartbeat verification script ====="
cat > "$VERIFY_PY" << 'PYEOF'
#!/usr/bin/env python3
"""
Automated post-reboot verification:
 - checks nvgetty is masked
 - checks /dev/ttyTHS1 exists with correct permissions
 - listens for a MAVLink heartbeat from the Pixhawk with a timeout
No user interaction required.
"""
import subprocess
import sys
import os

RESULT_LOG = os.path.expanduser("~/uart_verify_result.log")

def log(msg):
    line = msg
    print(line)
    with open(RESULT_LOG, "a") as f:
        f.write(line + "\n")

def check_service():
    out = subprocess.run(["systemctl", "status", "nvgetty"],
                          capture_output=True, text=True)
    combined = (out.stdout + out.stderr).lower()
    if "masked" in combined or "not found" in combined or "could not be found" in combined:
        log("[OK] nvgetty service is disabled/masked.")
        return True
    log("[WARN] nvgetty does not appear masked:\n" + combined)
    return False

def check_port():
    if not os.path.exists("/dev/ttyTHS1"):
        log("[FAIL] /dev/ttyTHS1 does not exist.")
        return False
    out = subprocess.run(["ls", "-l", "/dev/ttyTHS1"], capture_output=True, text=True)
    log(f"[INFO] Port permissions: {out.stdout.strip()}")
    if "dialout" in out.stdout:
        log("[OK] /dev/ttyTHS1 exists and is owned by dialout group.")
        return True
    log("[WARN] /dev/ttyTHS1 exists but dialout group not detected.")
    return False

def check_heartbeat(timeout=15):
    try:
        from pymavlink import mavutil
    except ImportError:
        log("[FAIL] pymavlink not installed.")
        return False
    log(f"[INFO] Listening for MAVLink heartbeat on /dev/ttyTHS1 (timeout {timeout}s)...")
    try:
        conn = mavutil.mavlink_connection("/dev/ttyTHS1", baud=115200)
        msg = conn.wait_heartbeat(timeout=timeout)
        if msg:
            log(f"[OK] Heartbeat received! System ID: {conn.target_system}, "
                f"Component ID: {conn.target_component}")
            return True
        log("[FAIL] No heartbeat received (Link Down). Check wiring/baud rate/power.")
        return False
    except Exception as e:
        log(f"[FAIL] Error opening connection: {e}")
        return False

if __name__ == "__main__":
    open(RESULT_LOG, "w").close()
    log("===== UART / Pixhawk Verification =====")
    ok_service = check_service()
    ok_port = check_port()
    ok_heartbeat = check_heartbeat()
    log("========================================")
    if ok_service and ok_port and ok_heartbeat:
        log("RESULT: ALL CHECKS PASSED. UART + Pixhawk link is working.")
    else:
        log("RESULT: One or more checks failed. Review log above.")
    log("To manually watch live MAVLink traffic and test mode switches, run:")
    log("  mavproxy.py --master=/dev/ttyTHS1 --baudrate=115200")
    log("(mode switching e.g. 'mode GUIDED' / 'mode LOITER' still requires manual input")
    log(" since it triggers a physical action/beep on the real drone.)")
PYEOF
chmod +x "$VERIFY_PY"
chown "$REAL_USER":"$REAL_USER" "$VERIFY_PY"

log "===== STEP 6: Register one-shot systemd service to auto-run verification after reboot ====="
sudo tee "/etc/systemd/system/${SERVICE_NAME}" > /dev/null << EOF
[Unit]
Description=One-shot UART/Pixhawk verification after reboot
After=multi-user.target

[Service]
Type=oneshot
User=${REAL_USER}
ExecStart=/usr/bin/python3 ${VERIFY_PY}
ExecStartPost=/bin/systemctl disable ${SERVICE_NAME}

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "${SERVICE_NAME}"

log "===== Setup complete. Rebooting in 10 seconds. ====="
log "After reboot, verification runs AUTOMATICALLY."
log "Check results anytime with:  cat ~/uart_verify_result.log"
sleep 10
sudo reboot
