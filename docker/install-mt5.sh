#!/bin/bash
# Install the MetaTrader 5 terminal into the Wine prefix. Build time only.
#
# The previous version of this could not fail. wget ran with -q and no check,
# the installer's result was never looked at, and the script exited 0 whether
# terminal64.exe existed or not - so a download that went wrong produced an
# image that built green and had no terminal in it. Every step here either
# succeeds or stops the build with a reason.
set -euo pipefail

# MetaQuotes' generic installer, on purpose: the image is meant to be public
# and broker-neutral. The broker's server list is supplied at runtime (see
# configure_terminal.py).
URL="https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"
ATTEMPTS=3
TIMEOUT=900   # seconds for one installer run; it downloads ~100 MB itself

log() { echo "==> install-mt5: $*"; }

find_terminal() {
    find "$WINEPREFIX/drive_c" -name terminal64.exe -type f 2>/dev/null | head -1
}

run_installer() {
    # The installer downloads the actual terminal, installs it and then usually
    # starts it. That last step means "wait for wineserver" never returns, so
    # this waits for the installer process itself to go away.
    Xvfb :99 -screen 0 1280x800x24 >/dev/null 2>&1 &
    local xvfb=$!
    sleep 2
    DISPLAY=:99 wine /tmp/mt5setup.exe /auto /path:"C:\\Metatrader-5" &
    local start
    start=$(date +%s)
    local finished=0
    while [ $(( $(date +%s) - start )) -lt $TIMEOUT ]; do
        sleep 10
        if ! pgrep -f 'mt5setup\.exe' >/dev/null; then
            # Give a just-started terminal a moment to write its config.
            sleep 20
            finished=1
            break
        fi
    done
    if [ $finished -eq 0 ]; then
        # A hang says nothing by itself. What is still running (a crash
        # dialog shows up as winedbg) and how far the install got usually do.
        log "installer still running after ${TIMEOUT}s; Wine processes:"
        ps -eo pid,etime,args | grep -iE 'wine|\.exe' | grep -v grep || true
        log "files under drive_c (newest first):"
        find "$WINEPREFIX/drive_c" -newer /tmp/mt5setup.exe -type f -printf '%TT %s %p\n' 2>/dev/null \
            | sort -r | head -20 || true
    fi
    wineserver -k || true
    kill $xvfb 2>/dev/null || true
    wait 2>/dev/null || true
}

for attempt in $(seq 1 $ATTEMPTS); do
    log "attempt $attempt/$ATTEMPTS: downloading mt5setup.exe"
    rm -f /tmp/mt5setup.exe
    if ! wget --tries=5 --timeout=60 --waitretry=10 -O /tmp/mt5setup.exe "$URL"; then
        log "download failed"
        continue
    fi
    # A captive portal or an error page is a successful download of the wrong
    # thing. A real installer is a few MB and starts with "MZ".
    if [ "$(head -c 2 /tmp/mt5setup.exe)" != "MZ" ]; then
        log "downloaded file is not a Windows executable ($(stat -c %s /tmp/mt5setup.exe) bytes)"
        continue
    fi
    log "running installer ($(stat -c %s /tmp/mt5setup.exe) bytes)"
    run_installer || true
    [ -n "$(find_terminal)" ] && break
    log "installer finished but no terminal64.exe was found"
done
rm -f /tmp/mt5setup.exe

TERMINAL=$(find_terminal)
if [ -z "$TERMINAL" ]; then
    log "FAILED: terminal64.exe not found after $ATTEMPTS attempts"
    exit 1
fi

# /path: is honoured by current installers, but not by every build that has
# ever been published. Everything else expects C:\Metatrader-5, so move it
# there rather than chasing wherever it landed.
INSTALLED_DIR=$(dirname "$TERMINAL")
if [ "$INSTALLED_DIR" != "$MT5_DIR" ]; then
    log "installed to $INSTALLED_DIR; moving to $MT5_DIR"
    rm -rf "$MT5_DIR"
    mv "$INSTALLED_DIR" "$MT5_DIR"
fi

# Settings the terminal reads at start. Written after the installer's own
# launch has been killed, so nothing overwrites them. Both files are UTF-16LE
# with a BOM, which is what the terminal writes itself.
#   LiveUpdate off: keep the terminal on the build this image was made with
#   instead of self-updating at runtime into something untested.
mkdir -p "$MT5_DIR/Config"
{ printf '\xFF\xFE'; printf '[LiveUpdate]\r\nLiveUpdateMode=2\r\n' | iconv -f UTF-8 -t UTF-16LE; } \
    > "$MT5_DIR/Config/terminal.ini"
{ printf '\xFF\xFE'; printf '[Experts]\r\nEnabled=1\r\nAllowLiveTrading=1\r\nAccount=0\r\nProfile=0\r\n' | iconv -f UTF-8 -t UTF-16LE; } \
    > "$MT5_DIR/Config/common.ini"

# Record which build this is, so CI can tag the image with it and skip
# publishing when MetaQuotes has not released anything new. The version lives
# in the PE's version resource as a UTF-16 "FileVersion" string.
python3 - "$MT5_DIR/terminal64.exe" > /opt/mt5-version <<'PY'
import re, sys
data = open(sys.argv[1], "rb").read()
key = "FileVersion".encode("utf-16-le")
i = data.find(key)
if i < 0:
    print("unknown"); sys.exit(0)
tail = data[i + len(key): i + len(key) + 128].decode("utf-16-le", "ignore")
m = re.search(r"\d+\.\d+\.\d+\.\d+", tail)
print(m.group(0) if m else "unknown")
PY

# The sample programs. The terminal compiles every .mq5 it finds without an
# .ex5 at start-up, one or two seconds each under Wine, and does not answer
# IPC until it is done - so they cost minutes on every container start, and
# space in the image. The API needs none of them. MQL5/Include stays: it is
# what compiling your own code needs.
for dir in Experts Indicators Scripts Services; do
    find "$MT5_DIR/MQL5/$dir" -mindepth 1 -delete 2>/dev/null || true
done

# The terminal writes logs and caches on its first run; none of it belongs in
# the image.
rm -rf "$MT5_DIR/logs"/* "$MT5_DIR/Bases"/*/history "$MT5_DIR/Bases"/*/ticks \
       "$WINEPREFIX/drive_c/users/root/AppData/Local/Temp"/* /tmp/.X* 2>/dev/null || true

log "installed MetaTrader 5 build $(cat /opt/mt5-version) at $MT5_DIR ($(du -sh "$MT5_DIR" | cut -f1))"
