# MetaTrader 5 under Wine, with an HTTP API in front of it.
#
# Layers are ordered by how often they change, so a code change rebuilds in
# seconds and a new terminal build only re-runs the last two layers:
#
#   1. Packages (Wine from WineHQ, VNC, noVNC, supervisor)
#   2. Wine prefix + Windows Python
#   3. Python dependencies, installed into that Windows Python
#   4. The MetaTrader 5 terminal itself            <- MT5_CACHE_BUST
#   5. Scripts and API code
#
# The previous image started from tobix/pywine (Debian 11, EOL, Wine 7),
# installed MT5, then upgraded Wine in a later layer. The old Wine stayed in
# the lower layer and the new one was added on top, which is a large part of
# why the image was over 7 GB. Here Wine is installed once.

# ============================================================ MT5 installer
# mt5setup.exe hangs under WineHQ 11 (it ran to the timeout on every attempt)
# and completes under Debian's own Wine 10.0, while the terminal needs the
# newer Wine at runtime for IPC. The original image hit the same split and
# solved it by installing under Wine 7 and upgrading Wine afterwards, which
# left two Wines in the image. Here the installer gets its own throwaway stage
# and only the installed folder is copied into the final image: the terminal
# runs with /portable, so that folder is self-contained.
FROM debian:trixie-slim AS mt5

ENV DEBIAN_FRONTEND=noninteractive \
    WINEPREFIX=/opt/wineprefix \
    WINEARCH=win64 \
    WINEDEBUG=-all \
    WINEDLLOVERRIDES="mscoree,mshtml=" \
    MT5_DIR=/opt/wineprefix/drive_c/Metatrader-5

RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        wine wine64 wine32:i386 fonts-wine \
        libgnutls30t64 libgnutls30t64:i386 \
        xvfb xauth procps python3 ca-certificates wget && \
    rm -rf /var/lib/apt/lists/* && \
    xvfb-run -a sh -c 'wineboot --init && wineserver -w && winecfg -v win10 && wineserver -w'

# mt5setup.exe is a web installer that always fetches the newest terminal.
# Changing MT5_CACHE_BUST is how the CI forces a fresh download; otherwise
# this stage comes from cache like any other.
ARG MT5_CACHE_BUST=0
COPY docker/install-mt5.sh /usr/local/bin/install-mt5.sh
RUN sed -i 's/\r$//' /usr/local/bin/install-mt5.sh && \
    chmod +x /usr/local/bin/install-mt5.sh && \
    echo "cache bust: ${MT5_CACHE_BUST}" && \
    install-mt5.sh

# ============================================================== final image
FROM debian:trixie-slim

LABEL org.opencontainers.image.description="MetaTrader 5 terminal under Wine, with an HTTP API"

ENV DEBIAN_FRONTEND=noninteractive \
    WINEPREFIX=/opt/wineprefix \
    WINEARCH=win64 \
    WINEDEBUG=-all \
    # No Mono and no Gecko: MT5 needs neither, and without this wineboot
    # stops to ask whether to download them.
    WINEDLLOVERRIDES="mscoree,mshtml=" \
    DISPLAY=:0 \
    VNC_GEOMETRY=1280x800 \
    MT5_DIR=/opt/wineprefix/drive_c/Metatrader-5

# ---------------------------------------------------------------- 1. packages
# Wine from WineHQ, as in the image that worked (it ran winehq-stable). An
# IPC timeout seen on Debian's 10.0 was first blamed on Wine; the likelier
# cause was the stale MetaTrader5 package (see section 4). Pinned so a rebuild does not
# silently move to a Wine nobody has tried; bump WINE_VERSION deliberately.
# (apt-cache madison winehq-stable lists what is available.)
#
# The i386 half is needed even though the terminal and Python are 64-bit:
# both installers (mt5setup.exe and Python's bootstrapper) are 32-bit.
# libgnutls is only a Recommends, but without it Wine has no TLS and
# mt5setup.exe cannot download the terminal.
#
# WineHQ ships its Windows-side DLLs with their debug symbols: 1.4 GB of
# them, and Wine copies the same files again into the prefix in section 2.
# Stripping the symbols takes them to about 530 MB and keeps the "Wine
# builtin DLL" marker Wine identifies its own DLLs by. It has to happen in
# this same RUN, or the unstripped copies stay in the layer underneath.
# The .a files next to them are import libraries for compiling Winelib
# programs, never used to run anything - and strip *inflates* them (from
# 31 MB to over 400), so they are deleted first rather than stripped.
# STRIP_WINE=0 skips it, in case a Wine release ever objects.
ARG WINE_VERSION=11.0.0.0~trixie-1
ARG STRIP_WINE=1
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates wget && \
    mkdir -pm755 /etc/apt/keyrings && \
    wget -q -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key && \
    wget -q -O /etc/apt/sources.list.d/winehq-trixie.sources \
        https://dl.winehq.org/wine-builds/debian/dists/trixie/winehq-trixie.sources && \
    dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        winehq-stable=${WINE_VERSION} wine-stable=${WINE_VERSION} \
        wine-stable-amd64=${WINE_VERSION} wine-stable-i386=${WINE_VERSION} \
        libgnutls30t64 libgnutls30t64:i386 \
        tigervnc-standalone-server tigervnc-tools \
        novnc python3-websockify \
        openbox supervisor procps xdotool wmctrl \
        xvfb xauth \
        ca-certificates wget && \
    if [ "$STRIP_WINE" = "1" ]; then \
        apt-get install -y --no-install-recommends binutils && \
        find /opt/wine-stable/lib/wine/x86_64-windows /opt/wine-stable/lib/wine/i386-windows \
            -type f -name '*.a' -delete && \
        find /opt/wine-stable/lib/wine/x86_64-windows /opt/wine-stable/lib/wine/i386-windows \
            -type f -exec strip --strip-debug {} + 2>/dev/null ; \
        apt-get purge -y --auto-remove binutils && \
        du -sh /opt/wine-stable/lib/wine/*-windows ; \
    fi && \
    rm -rf /var/lib/apt/lists/* /usr/share/doc/* /usr/share/man/* && \
    # Open noVNC's viewer, already connecting, at the root of port 6901.
    printf '<meta http-equiv="refresh" content="0; url=vnc.html?autoconnect=true&resize=remote&reconnect=true">\n' \
        > /usr/share/novnc/index.html

# --------------------------------------------- 2. Wine prefix + Windows Python
# Python 3.9 because every pinned dependency (numpy 1.22, pandas 1.4, pydantic
# 1) has been running on it; moving to a newer one is a separate change.
ARG PYTHON_VERSION=3.9.13
RUN wget -q --tries=5 --timeout=60 -O /tmp/python.exe \
        "https://www.python.org/ftp/python/${PYTHON_VERSION}/python-${PYTHON_VERSION}-amd64.exe" && \
    xvfb-run -a sh -c '\
        wineboot --init && wineserver -w && \
        winecfg -v win10 && \
        wine /tmp/python.exe /quiet InstallAllUsers=1 PrependPath=1 TargetDir=C:\\Python \
            Include_doc=0 Include_test=0 Include_tcltk=0 Include_launcher=0 && \
        wineserver -w' && \
    rm -f /tmp/python.exe && \
    wine python --version

# ----------------------------------------------------------- 3. Python deps
COPY api/requirements.txt /tmp/api-requirements.txt
COPY docker/requirements.txt /tmp/requirements.txt
RUN wine python -m pip install --no-cache-dir --upgrade pip wheel && \
    wine python -m pip install --no-cache-dir \
        -r /tmp/api-requirements.txt -r /tmp/requirements.txt && \
    wineserver -w && \
    rm -rf /tmp/*requirements.txt "$WINEPREFIX/drive_c/users/root/AppData/Local/pip" /tmp/*

# -------------------------------------------------------------- 4. MetaTrader
# The terminal is installed in the `mt5` stage above; see there for why.
#
# The MetaTrader5 Python package is installed here, next to it, and not with
# the other requirements. It talks to the terminal over IPC and MetaQuotes
# releases it in step with terminal builds: the old pin (5.0.5640, February)
# against a September terminal gave "IPC timeout (-10005)" on every
# mt5.initialize(), with or without credentials. Both are "newest at build
# time" and share MT5_CACHE_BUST, so they are always refreshed together.
ARG MT5_CACHE_BUST=0
COPY --from=mt5 /opt/wineprefix/drive_c/Metatrader-5 /opt/wineprefix/drive_c/Metatrader-5
COPY --from=mt5 /opt/mt5-version /opt/mt5-version
RUN echo "cache bust: ${MT5_CACHE_BUST}" && \
    wine python -m pip install --no-cache-dir --upgrade MetaTrader5 && \
    wineserver -w && \
    echo "terminal $(cat /opt/mt5-version), python package $(wine python -m pip show MetaTrader5 | grep ^Version)"

# -------------------------------------------------------------- 5. app code
COPY docker/supervisord.conf /etc/supervisor/supervisord.conf
COPY docker/entrypoint.sh docker/run-mt5.sh docker/run-server.sh docker/dismiss-liveupdate.sh docker/configure_terminal.py /usr/local/bin/
COPY api /app
# CRLF guard: a checkout on Windows with core.autocrlf turns every script into
# "bad interpreter: /bin/bash^M". .gitattributes prevents it; this makes sure.
RUN cd /usr/local/bin && \
    sed -i 's/\r$//' entrypoint.sh run-mt5.sh run-server.sh dismiss-liveupdate.sh configure_terminal.py /etc/supervisor/supervisord.conf && \
    chmod +x entrypoint.sh run-mt5.sh run-server.sh dismiss-liveupdate.sh && \
    rm -rf /app/tests

WORKDIR /app
EXPOSE 6901 8000

# /health answers once the API is up, which is after the terminal is running.
HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1:8000/health || exit 1

CMD ["/usr/local/bin/entrypoint.sh"]
