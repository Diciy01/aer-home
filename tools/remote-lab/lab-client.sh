#!/bin/bash
# TEST CLIENT: Remmina on an isolated Xvfb display with its own config dirs and
# a D-Bus without service activation (no access to the user's keyring).
#   tools/remote-lab/lab-client.sh <lab-dir> <display> <rdp-uri>
D=$(readlink -f "$1"); X=$2; mkdir -p "$D/client"/{config,data,cache}
pgrep -f "Xvfb $X " >/dev/null || { Xvfb "$X" -screen 0 1600x1000x24 -nolisten tcp > "$D/xvfb.log" 2>&1 & sleep 1; }
export DISPLAY=$X GDK_BACKEND=x11 XDG_CONFIG_HOME=$D/client/config XDG_DATA_HOME=$D/client/data XDG_CACHE_HOME=$D/client/cache
unset WAYLAND_DISPLAY
exec setsid dbus-run-session --config-file="$(dirname "$(readlink -f "$0")")/bus.conf" -- remmina -c "$3"
