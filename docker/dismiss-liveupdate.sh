#!/bin/bash
# Close the terminal's LiveUpdate window ("Restart" / "Later") whenever it
# appears.
#
# The terminal downloads a newer build on its own and then asks to restart
# into it. There is no setting that stops this (LiveUpdateMode in
# terminal.ini does not), and the window is not harmless: while it is open
# it can block the IPC the API depends on. Restarting into the update would
# not help either - the container starts again from the image, so the update
# is fetched and offered again on every start. The image is instead rebuilt
# weekly with the current build (see .github/workflows/docker.yml).
#
# The window is found by its title rather than clicked at fixed coordinates,
# which is what the old VNC script did and which broke whenever the window
# moved or the resolution changed.

while true; do
    for w in $(xdotool search --onlyvisible --name 'LiveUpdate' 2>/dev/null); do
        echo "LiveUpdate window found ($w); closing it (= Later)"
        # A polite close: the window manager sends WM_CLOSE, which Wine
        # turns into the dialog's own cancel - the same as clicking X.
        wmctrl -i -c "$w" 2>/dev/null
        sleep 3
        if xdotool search --onlyvisible --name 'LiveUpdate' 2>/dev/null | grep -qx "$w"; then
            echo "still open; sending Escape"
            xdotool windowactivate --sync "$w" key --clearmodifiers Escape 2>/dev/null
        fi
    done
    sleep 5
done
