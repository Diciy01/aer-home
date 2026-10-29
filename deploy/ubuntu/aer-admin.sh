#!/usr/bin/env bash
# aer-admin — owner tasks of AER Core / Gateway on the server (ADR-018).
# Runs as root on the server itself and talks to Core on loopback with the
# owner token from Core's data directory. The token never appears in argv,
# environment of child processes or output.
#
#   aer-admin gateway-credential          create the Gateway's agent credential
#   aer-admin fingerprint                 Gateway certificate SHA-256 (what clients pin)
#   aer-admin enroll-code NAME [N] [HOURS]  code for N new AER Connect devices (shown once)
#   aer-admin enrollments                 list enrollment codes (never the codes)
#   aer-admin devices                     list registered devices
#   aer-admin revoke-device DEVICE_ID     revoke a device (both credentials, sessions)
#   aer-admin health                      services, Core and Gateway health, pin check
#   aer-admin backup DIR                  consistent backup (stops services briefly)
#   aer-admin restore ARCHIVE --yes       restore; the current state is kept aside
set -euo pipefail
core=http://127.0.0.1:8787/api/v1
data=/var/lib/aer-home/core
gwstate=/var/lib/aer-remote-gateway
etc=/etc/aer-home
die() { echo "aer-admin: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root (sudo)"
command -v curl >/dev/null || die "curl is required"
command -v python3 >/dev/null || die "python3 is required"

# api METHOD PATH [JSON] — owner call; the bearer header goes through
# curl's config on stdin, not argv.
api() {
  local tok
  local args=(-fsS -K - -X "$1" -H 'Content-Type: application/json')
  [ $# -ge 3 ] && args+=(--data "$3")
  tok=$(cat "$data/core.token") || die "owner token not readable (is aer-core installed and started?)"
  printf 'header = "Authorization: Bearer %s"\n' "$tok" | curl "${args[@]}" "$core$2"
}

# json CODE — run Python on the envelope's data as d (statements on new lines).
json() {
  python3 -c "import json,sys
raw=sys.stdin.read()
if not raw.strip(): sys.exit(1)  # curl already reported the HTTP error
d=json.loads(raw)['data']
$1"
}

case "${1:-}" in
gateway-credential)
  [ -e "$etc/gateway.token" ] && die "$etc/gateway.token exists; revoke the old Gateway agent in AER HOME first"
  server=$(api POST /registry/entities '{"name":"Домашний сервер (Gateway)","type":"server"}' | json 'print(d["id"])')
  umask 077
  api POST /monitoring/agents "{\"entityId\":\"$server\",\"name\":\"gateway\",\"kind\":\"gateway\"}" |
    json 'print(d["token"])' > "$etc/gateway.token.new"
  chmod 0600 "$etc/gateway.token.new"
  mv "$etc/gateway.token.new" "$etc/gateway.token"
  echo "Gateway credential written to $etc/gateway.token (0600, root; passed to the service as a systemd credential)"
  ;;
fingerprint)
  /usr/local/bin/aer-remote-gateway -config "$etc/remote-gateway.json" -fingerprint
  ;;
enroll-code)
  name=${2:-}
  [ -n "$name" ] || die "usage: aer-admin enroll-code NAME [DEVICES] [HOURS]"
  body=$(python3 -c 'import json,sys; print(json.dumps({"name":sys.argv[1],"maxUses":int(sys.argv[2]),"hours":int(sys.argv[3])}))' "$name" "${3:-1}" "${4:-24}")
  api POST /remote/enrollments "$body" |
    json 'e=d["enrollment"]
print("Код регистрации:", d["code"])
print("Устройств:", e["maxUses"], " до:", e["expiresAt"])
print("Показывается один раз и нигде не хранится.")'
  ;;
enrollments)
  api GET /remote/enrollments | json 'for e in d: print(e["id"], e["name"], str(e["uses"]) + "/" + str(e["maxUses"]), "активен" if e["active"] else "не активен", e["expiresAt"])'
  ;;
devices)
  api GET /remote/devices | json 'for x in d: print(x["id"], x["number"], x["status"], x["name"], x["lastSeenAt"] or "-")'
  ;;
revoke-device)
  [ -n "${2:-}" ] || die "usage: aer-admin revoke-device DEVICE_ID"
  api POST "/remote/devices/$2/revoke" | json 'print(d["number"], d["status"])'
  ;;
health)
  ok=0
  for s in aer-core aer-remote-gateway; do
    printf '%-22s %s\n' "$s" "$(systemctl is-active "$s" || true)"
  done
  curl -fsS "$core/health" >/dev/null && echo "core /health        ok" || { echo "core /health        FAIL"; ok=1; }
  port=$(python3 -c 'import json; print(json.load(open("/etc/aer-home/remote-gateway.json"))["listenAddr"].rsplit(":",1)[1])')
  # -k only for this local probe: the pin is compared right below.
  curl -fsSk "https://127.0.0.1:$port/gw/v1/health" >/dev/null && echo "gateway /gw/v1/health ok" || { echo "gateway /gw/v1/health FAIL"; ok=1; }
  if command -v openssl >/dev/null; then
    want=$(/usr/local/bin/aer-remote-gateway -config "$etc/remote-gateway.json" -fingerprint | tr 'A-F' 'a-f')
    got=$(openssl s_client -connect "127.0.0.1:$port" </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2 | tr 'A-F' 'a-f')
    [ "$want" = "$got" ] && echo "gateway certificate matches the pinned fingerprint" || { echo "gateway certificate MISMATCH"; ok=1; }
  fi
  exit $ok
  ;;
backup)
  dest=${2:-}
  [ -n "$dest" ] || die "usage: aer-admin backup DIR"
  install -d -m 0700 "$dest"
  out="$dest/aer-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  echo "stopping services for a consistent copy…"
  systemctl stop aer-remote-gateway aer-core
  trap 'systemctl start aer-core aer-remote-gateway' EXIT
  umask 077
  tar -czf "$out" -C / "${data#/}" "${gwstate#/}" "${etc#/}"
  sha256sum "$out" > "$out.sha256"
  echo "backup: $out (contains the owner token, credentials and the Gateway TLS key — keep it private)"
  ;;
restore)
  arch=${2:-}
  [ -f "$arch" ] && [ "${3:-}" = "--yes" ] || die "usage: aer-admin restore ARCHIVE --yes"
  if [ -f "$arch.sha256" ]; then (cd "$(dirname "$arch")" && sha256sum -c "$(basename "$arch").sha256") || die "checksum mismatch"; fi
  tar -tzf "$arch" | grep -Ev "^(${data#/}|${gwstate#/}|${etc#/})(/|$)" && die "archive contains unexpected paths"
  systemctl stop aer-remote-gateway aer-core
  aside="-before-restore-$(date +%Y%m%d-%H%M%S)"
  for d in "$data" "$gwstate" "$etc"; do [ -e "$d" ] && mv "$d" "$d$aside"; done
  tar -xzf "$arch" -C /
  chown -R aer-core:aer-core "$data"
  chown -R aer-gateway:aer-gateway "$gwstate"
  systemctl start aer-core aer-remote-gateway
  echo "restored; previous state kept with suffix $aside (remove it yourself once verified)"
  ;;
*)
  sed -n '2,17p' "$0"
  exit 2
  ;;
esac
