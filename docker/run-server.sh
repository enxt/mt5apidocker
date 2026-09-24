#!/bin/bash
# Start the API once the terminal is running.
#
# The API's connector waits for LOGIN_MARKER before calling mt5.initialize().
# The terminal now logs itself in from startup.ini, so the marker means "the
# terminal process exists and has had time to start", nothing more. If the
# login has not finished by then the connector simply retries, and falls back
# to passing the credentials itself.
LOGIN_MARKER="/tmp/login_complete"
STARTUP_GRACE="${MT5_STARTUP_GRACE:-20}"

echo "Waiting for the MetaTrader 5 terminal to start..."
until pgrep -f 'terminal64.exe' >/dev/null 2>&1; do
    sleep 2
done
sleep "$STARTUP_GRACE"
echo "1" > "$LOGIN_MARKER"

echo "Starting FastAPI Server..."
cd /app
exec wine python -m app
