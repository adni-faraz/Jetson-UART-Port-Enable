# Jetson UART Auto-Setup for Pixhawk

A single script that fully automates enabling the hardware UART port on an
NVIDIA Jetson (Orin) and verifying a MAVLink heartbeat link to a Pixhawk
flight controller — including automatic re-verification after the required
reboot.

## What it does

1. Stops, disables, and masks the `nvgetty` service (which normally grabs
   pins 8 & 10 for a serial console).
2. Clones and runs [JetsonHacks' `jetson-orin-uart`](https://github.com/jetsonhacks/jetson-orin-uart)
   installer, which sets the correct udev rules and adds your user to the
   `dialout` group.
3. Installs all required packages: `python3-serial`, `python3-pip`,
   `pymavlink`, `mavproxy`, and build dependencies (`libxml2-dev`,
   `libxslt1-dev`).
4. Adds your user to the `dialout` group (so no `sudo` is needed to access
   the serial port).
5. Writes `~/verify_uart_heartbeat.py`, a script that checks:
   - `nvgetty` is masked
   - `/dev/ttyTHS1` exists with the correct `dialout` group permissions
   - a live MAVLink heartbeat can be received from the Pixhawk (with a
     timeout, so it never hangs indefinitely)
6. Registers a one-shot `systemd` service that automatically runs the
   verification script the moment the Jetson finishes rebooting, then
   disables itself so it only ever fires once.
7. Reboots the Jetson automatically (10-second countdown) to apply the
   UART/group changes.

## Requirements

- NVIDIA Jetson (Orin series) running L4T/JetPack
- Pixhawk flight controller wired to the Jetson's UART pins (8 & 10)
- Internet access on the Jetson (for `git clone` and `apt`/`pip` installs)
- A user account with `sudo` privileges

## Usage

```bash
git clone https://github.com/adni-faraz/Jetson-UART-Port-Enable.git
cd Jetson_UART-Port-Enable
chmod +x setup_jetson_uart.sh
./setup_jetson_uart.sh
```

The script will run through all setup steps, print progress to your
terminal and to `~/uart_setup.log`, then reboot automatically.

## After reboot

Verification runs automatically — no need to SSH in and run anything by
hand. Once the Jetson is back up, check the result:

```bash
cat ~/uart_verify_result.log
```

A successful run looks like:

```
[OK] nvgetty service is disabled/masked.
[OK] /dev/ttyTHS1 exists and is owned by dialout group.
[OK] Heartbeat received! System ID: 1, Component ID: 1
RESULT: ALL CHECKS PASSED. UART + Pixhawk link is working.
```

If the heartbeat check fails, double-check:
- TX/RX wiring isn't swapped between Jetson and Pixhawk
- Baud rate matches your flight controller's `SERIALx_BAUD` param
  (default assumed here: 115200, can be 57600 as well)
- The Pixhawk is powered and its serial port is configured for MAVLink

## Manual live monitoring (optional)

To watch raw MAVLink traffic yourself, or to test flight mode switching:

```bash
mavproxy.py --master=/dev/ttyTHS1 --baudrate=115200
```

From the MAVProxy console you can run, for example:

```
mode GUIDED
mode LOITER
```

**Note:** mode switching is intentionally left as a manual step — it
triggers a real, physical action (and an audible beep) on the actual
drone, so it can't be safely automated by a setup script.

## Files

| File | Purpose |
|---|---|
| `setup_jetson_uart.sh` | Main automated setup script (run once) |
| `~/verify_uart_heartbeat.py` | Generated on first run; re-runs automatically after every install via systemd |
| `~/uart_setup.log` | Log of the setup steps |
| `~/uart_verify_result.log` | Log of the post-reboot verification result |

## Re-running / troubleshooting

The script is idempotent — it's safe to run again if something fails
partway through (it will re-clone the JetsonHacks repo and re-run all
steps). If you need to remove the one-shot verification service manually:

```bash
sudo systemctl disable uart-verify.service
sudo rm /etc/systemd/system/uart-verify.service
sudo systemctl daemon-reload
```
