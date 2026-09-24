#!/bin/bash
# Keep the terminal running. Supervisor restarts this script; this script
# restarts the terminal.
#
# The terminal logs in by itself from startup.ini (written by
# configure_terminal.py), so there is nothing to type into its window.

MT5_DIR="${MT5_DIR:-/opt/wineprefix/drive_c/Metatrader-5}"

if [ ! -f "$MT5_DIR/terminal64.exe" ]; then
    # The build fails when the install does, so this means the image is not
    # the one this script was built with.
    echo "FATAL: $MT5_DIR/terminal64.exe is missing from the image"
    sleep 60
    exit 1
fi

# Is a terminal already up? MT5 refuses a second instance on the same portable
# data directory and **exits 0 immediately** when it finds one - which is
# indistinguishable, to the loop below, from a clean shutdown. Without this
# check that once produced 11,945 relaunches in eighteen hours.
#
# `pgrep -f` rather than a PID file: the process that matters may have been
# started by a previous incarnation of this script.
terminal_running() {
    pgrep -f 'terminal64.exe' >/dev/null 2>&1
}

while true; do
    if terminal_running; then
        # Do not launch a second one. Wait for the one that exists to go away,
        # which is the only event that should cause a launch.
        sleep 5
        continue
    fi

    echo "Launching MetaTrader 5..."
    wine "$MT5_DIR/terminal64.exe" /portable '/config:C:\Metatrader-5\startup.ini'
    EXIT_CODE=$?

    if terminal_running; then
        echo "MT5 exited (code $EXIT_CODE) but a terminal is still running — not relaunching."
        sleep 5
        continue
    fi

    echo "MT5 exited (code $EXIT_CODE) — restarting in 5s..."
    sleep 5
done
