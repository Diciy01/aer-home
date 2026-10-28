#!/bin/bash
# TEST HOST for AER Remote: an isolated headless GNOME Wayland session (own
# D-Bus, own XDG dirs, keyfile GSettings) with gnome-remote-desktop on a test
# port. Touches nothing of the logged-in user's session or settings.
#   tools/remote-lab/lab-host.sh <lab-dir> [port]
# Stop: kill the process group printed as "lab pid".
set -e
D=$(readlink -f "$1"); PORT=${2:-33891}; mkdir -p "$D"/{config,data,cache,state}
cat > "$D/env.sh" <<ENV
export AER_LAB_VMON=${AER_LAB_VMON:-1920x1080}
export XDG_CONFIG_HOME=$D/config XDG_DATA_HOME=$D/data XDG_CACHE_HOME=$D/cache XDG_STATE_HOME=$D/state
export GSETTINGS_BACKEND=keyfile
unset DISPLAY WAYLAND_DISPLAY
ENV
[ -f "$D/tls.crt" ] || openssl req -x509 -newkey rsa:2048 -nodes -keyout "$D/tls.key" -out "$D/tls.crt" -days 7 -subj "/CN=aer-remote-test" 2>/dev/null
chmod 600 "$D/tls.key"
cat > "$D/inner.sh" <<'INNER'
#!/bin/bash
D=$(dirname "$(readlink -f "$0")"); . "$D/env.sh"
# AER_LAB_VMON=none: no extra monitor — the RDP session's own virtual
# monitor is the only one, so new windows are always on the streamed screen.
VMON=${AER_LAB_VMON:-1920x1080}
gnome-shell --wayland --headless $([ "$VMON" = none ] || echo --virtual-monitor "$VMON") --wayland-display aer-remote-test > "$D/shell.log" 2>&1 &
for i in $(seq 1 100); do gdbus introspect --session --dest org.gnome.Mutter.RemoteDesktop --object-path /org/gnome/Mutter/RemoteDesktop >/dev/null 2>&1 && break; sleep 0.1; done
grdctl --headless rdp set-port "$PORT"; grdctl --headless rdp disable-port-negotiation
grdctl --headless rdp set-tls-cert "$D/tls.crt"; grdctl --headless rdp set-tls-key "$D/tls.key"
grdctl --headless rdp disable-view-only
grdctl --headless rdp disable          # AER agent enables it per session
# AER_LAB_DAEMON=1 starts the RDP daemon here (raw feasibility tests); with
# aer-remote-host the agent starts it per session (credentials are read only
# at daemon start).
[ "$AER_LAB_DAEMON" = 1 ] && /usr/libexec/gnome-remote-desktop-daemon --headless > "$D/grd.log" 2>&1 &
echo "$DBUS_SESSION_BUS_ADDRESS" > "$D/bus"
wait
INNER
sed -i "s/\"\$PORT\"/$PORT/" "$D/inner.sh"; chmod +x "$D/inner.sh"
setsid dbus-run-session -- "$D/inner.sh" > "$D/host.log" 2>&1 &
echo "lab pid $!"
