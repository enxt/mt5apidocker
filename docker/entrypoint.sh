#!/bin/bash
set -e

# Stale state from a previous run (docker restart): the login marker, so the
# API waits for this terminal and not the last one, and the X11 lock, which
# otherwise makes the VNC server fail with "display already in use".
rm -f /tmp/login_complete /tmp/.X0-lock /tmp/.X11-unix/X0

python3 /usr/local/bin/configure_terminal.py

# VNC password. Without one the VNC server accepts anyone who can reach it,
# which is only acceptable because docker-compose publishes on 127.0.0.1.
mkdir -p /root/.vnc
if [ -n "${VNC_PASSWORD:-}" ]; then
    echo "$VNC_PASSWORD" | vncpasswd -f > /root/.vnc/passwd
    chmod 600 /root/.vnc/passwd
    export VNC_SECURITY="-rfbauth /root/.vnc/passwd"
else
    echo "==> WARNING: VNC_PASSWORD is empty; VNC has no password"
    export VNC_SECURITY="-SecurityTypes None"
fi

echo "==> Starting services via supervisor..."
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
