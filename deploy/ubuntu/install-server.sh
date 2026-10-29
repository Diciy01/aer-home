#!/usr/bin/env bash
# Installs or upgrades AER Core + AER Remote Gateway on Ubuntu Server
# (ADR-017/018). Usage:
#   sudo ./install-server.sh /path/to/linux-binaries
# The directory must contain aer-core and aer-remote-gateway (linux/amd64).
# It never touches the firewall, the router, SSH or other services, and
# never enables or starts anything: the printed next steps are yours.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
die() { echo "install-server: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root (sudo)"
bin=${1:-}
[ -n "$bin" ] || die "usage: $0 <directory with aer-core and aer-remote-gateway>"
for b in aer-core aer-remote-gateway; do
  [ -f "$bin/$b" ] || die "$bin/$b missing"
done

for u in aer-core aer-gateway; do
  if ! id "$u" >/dev/null 2>&1; then
    useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$u"
    echo "created system user $u"
  fi
done

stamp=$(date +%Y%m%d-%H%M%S)
for b in aer-core aer-remote-gateway; do
  if [ -f "/usr/local/bin/$b" ]; then
    cp -p "/usr/local/bin/$b" "/usr/local/bin/$b.prev-$stamp"
    echo "kept previous /usr/local/bin/$b as $b.prev-$stamp"
  fi
  install -m 0755 "$bin/$b" "/usr/local/bin/$b.new"
  mv -f "/usr/local/bin/$b.new" "/usr/local/bin/$b"
done

install -d -m 0755 /etc/aer-home
for f in core.json remote-gateway.json; do
  if [ -e "/etc/aer-home/$f" ]; then
    echo "kept existing /etc/aer-home/$f (compare with $here/$f)"
  else
    install -m 0644 "$here/$f" "/etc/aer-home/$f"
  fi
done
for u in aer-core.service aer-remote-gateway.service; do
  install -m 0644 "$here/$u" "/etc/systemd/system/$u"
done
install -m 0755 "$here/aer-admin.sh" /usr/local/sbin/aer-admin
systemctl daemon-reload

cat <<EOF
Installed. Nothing was enabled or started; firewall and router are untouched.

First installation:
  sudo systemctl enable --now aer-core
  sudo aer-admin gateway-credential        # creates /etc/aer-home/gateway.token (0600)
  sudo systemctl enable --now aer-remote-gateway
  sudo aer-admin fingerprint               # give this to AER Connect users
  sudo aer-admin health

Upgrade (binaries replaced above, previous ones kept with .prev-$stamp):
  sudo aer-admin backup /var/backups/aer   # before restarting
  sudo systemctl restart aer-core aer-remote-gateway
  sudo aer-admin health

Publishing the Gateway to the internet (one TCP port, e.g. WAN 443 -> 8443)
is a separate decision of the owner after a review of this configuration.
EOF
