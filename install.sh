#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    echo 'Usage: sudo bash install.sh --domain proxy.example.com [--public-ip 203.0.113.10]'
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

domain=
public_ip=
while (($#)); do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --domain|--public-ip)
            (($# >= 2)) || die "Missing value for $1"
            if [[ $1 == --domain ]]; then domain=$2; else public_ip=$2; fi
            shift 2
            ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ ${#domain} -le 253 && $domain =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]*[a-z0-9]$ ]] ||
    die 'Provide a lowercase public hostname with --domain.'
[[ $EUID == 0 ]] || die 'Run as root or use sudo.'
source /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 && $(uname -m) == x86_64 && -d /run/systemd/system ]] ||
    die 'Requires Ubuntu 24.04 x86_64 with systemd.'

exec 9>/run/lock/tg-web-install.lock
flock -n 9 || die 'Another installation is running.'

mapfile -t addresses < <(getent ahostsv4 "$domain" | awk '{print $1}' | sort -u)
if [[ -z $public_ip ]]; then
    ((${#addresses[@]} == 1)) || die 'Set a single DNS A record or pass --public-ip.'
    public_ip=${addresses[0]}
fi
python3 - "$public_ip" "${addresses[@]}" <<'PY' || die 'The public IPv4 must be globally routable and present in DNS.'
import ipaddress
import sys

ip = ipaddress.IPv4Address(sys.argv[1])
sys.exit(not (ip.is_global and not ip.is_multicast and str(ip) in sys.argv[2:]))
PY

caddyfile=/etc/caddy/Caddyfile
config=/etc/telemt/telemt.toml
unit=/etc/systemd/system/telemt.service
link=/etc/telemt/webproxy.link
binary=/usr/local/bin/telemt
site=/var/www/tgweb

finish() {
    printf '\nSite: https://%s/\nTelegram WEB Proxy:\n' "$domain"
    cat "$link"
    printf '\nSaved for root in %s\n' "$link"
}

if [[ -f $link ]]; then
    grep -Fxq "host = \"$domain\"" "$config" &&
        grep -Fxq "public_addr = \"$public_ip:443\"" "$config" ||
        die 'An installation already exists with different settings.'
    systemctl is-active --quiet caddy && systemctl is-active --quiet telemt ||
        die 'An existing installation needs attention. Check systemctl status caddy telemt.'
    finish
    exit 0
fi

for path in /etc/telemt "$unit" "$binary" "$site"; do
    [[ ! -e $path && ! -L $path ]] || die "Existing deployment detected at $path."
done
[[ $(systemctl show telemt.service -p LoadState --value) == not-found ]] ||
    die 'An existing telemt.service was found.'

if [[ -e $caddyfile ]]; then
    package_hash=$(dpkg-query -W -f='${Conffiles}\n' caddy 2>/dev/null |
        awk '$1 == "/etc/caddy/Caddyfile" { print $2 }')
    [[ -n $package_hash && $(md5sum "$caddyfile" | awk '{print $1}') == "$package_hash" ]] ||
        die 'An existing custom Caddyfile was found.'
fi

listeners=$(ss -H -ltnp '( sport = :80 or sport = :443 or sport = :18080 )')
if [[ -n $listeners ]] && grep -v 'users:.*"caddy"' <<< "$listeners" >/dev/null; then
    die 'TCP port 80, 443 or 18080 is already in use.'
fi
[[ -z $(ss -H -ltn '( sport = :18080 )') ]] || die 'TCP port 18080 is already in use.'

work=$(mktemp -d)
changed=0
complete=0
cleanup() {
    local status=$?
    trap - EXIT
    if ((changed && !complete)); then
        echo 'Installation failed. Restoring the previous Caddy configuration.' >&2
        systemctl disable --now telemt.service >/dev/null 2>&1 || :
        rm -f -- "$unit" "$binary"
        rm -rf -- /etc/telemt "$site"
        cp -a -- "$work/Caddyfile.previous" "$caddyfile"
        systemctl daemon-reload
        if ! systemctl reload-or-restart caddy; then
            echo 'Caddy configuration restored. Check journalctl -u caddy.' >&2
        fi
    fi
    rm -rf -- "$work"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y caddy curl ca-certificates openssl
cp -a -- "$caddyfile" "$work/Caddyfile.previous"

version=3.5.17
archive=telemt-x86_64-linux-gnu.tar.gz
checksum=0570762ddcd79530d666b09e955b955bb52c9e134cc8b8ed1a0f50ad28d58a0e
curl --proto '=https' -fsSL --retry 3 --connect-timeout 10 --max-time 120 \
    "https://github.com/telemt/telemt/releases/download/$version/$archive" -o "$work/$archive"
printf '%s  %s\n' "$checksum" "$work/$archive" | sha256sum -c -
mkdir "$work/bin"
tar -xzf "$work/$archive" -C "$work/bin"
release_binary=$(find "$work/bin" -type f -name telemt -print -quit)
[[ -n $release_binary ]] || die 'Telemt executable missing in the release archive.'
[[ $("$release_binary" --version) == "telemt $version" ]] || die 'Unexpected Telemt version.'

cat > "$work/Caddyfile" <<EOF
{
    servers {
        protocols h1 h2
    }
}

$domain {
    encode gzip

    handle /telegram/web/* {
        reverse_proxy 127.0.0.1:18080 {
            header_up X-Forwarded-For {remote_host}
            flush_interval -1
        }
    }

    handle {
        root * $site
        file_server
    }
}
EOF
caddy validate --config "$work/Caddyfile" --adapter caddyfile

if ! id telemt >/dev/null 2>&1; then
    useradd --system --user-group --home-dir /var/lib/telemt --shell /usr/sbin/nologin telemt
fi

secret=$(openssl rand -hex 16)
changed=1
install -d -o root -g telemt -m 0750 /etc/telemt
install -d -m 0755 "$site"
install -m 0640 -o root -g telemt /dev/null "$config"
cat > "$config" <<EOF
[general]
use_middle_proxy = true
log_level = "normal"

[general.links]
show = ["web-user"]

[access.users]
web-user = "$secret"

[[server.listeners]]
ip = "127.0.0.1"
port = 18080
transport = "web"
proxy_protocol = false
reuse_allow = false
web_client_ip_source = "x_forwarded_for"
web_trusted_proxy_cidrs = ["127.0.0.1/32"]

[web]
enabled = true
carrier = "https"
decoy_fasttrack_mode = "off"
http_connection_capacity_action = "drop"

[[web.vhosts]]
host = "$domain"
base_path = "telegram/web"
public_addr = "$public_ip:443"

[web.vhosts.decoy]
mode = "static_directory"
directory = "$site"
index = "index.html"

[[web.vhosts.profiles]]
user = "web-user"
secret_mode = "dd"
max_sessions = 4
max_streams = 128
max_streams_per_session = 32
EOF

# The archive below contains the static NX Edge site bundled with this installer.
base64 -d > "$work/nx-edge.zip" <<'SITE_ARCHIVE'
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
kR8AAAAA
SITE_ARCHIVE
python3 -m zipfile -e "$work/nx-edge.zip" "$site"
find "$site" -type d -exec chmod 0755 {} +
find "$site" -type f -exec chmod 0644 {} +

install -m 0755 "$release_binary" "$binary"
install -m 0644 /dev/null "$unit"
cat > "$unit" <<'EOF'
[Unit]
Description=Telemt Telegram WEB Proxy
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=telemt
Group=telemt
StateDirectory=telemt
WorkingDirectory=/var/lib/telemt
ExecStart=/usr/local/bin/telemt /etc/telemt/telemt.toml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
NoNewPrivileges=true
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now telemt.service

ready=0
for ((attempt = 1; attempt <= 30; attempt++)); do
    status=$(curl -s --max-time 2 -o /dev/null -w '%{http_code}' \
        -H "Host: $domain" http://127.0.0.1:18080/telegram/web/ || :)
    if [[ $status == 200 || $status == 404 ]]; then ready=1; break; fi
    sleep 1
done
((ready)) || die 'Telemt listener did not become ready. Inspect journalctl -u telemt.'

install -m 0644 "$work/Caddyfile" "$caddyfile"
systemctl enable --now caddy
systemctl reload caddy

ready=0
for ((attempt = 1; attempt <= 30; attempt++)); do
    if [[ $(curl -fsS --max-time 3 --resolve "$domain:443:127.0.0.1" \
        "https://$domain/health.txt" 2>/dev/null || :) == NX_EDGE_OK ]]; then
        ready=1
        break
    fi
    sleep 2
done
((ready)) || die 'HTTPS check failed. Check public DNS and inbound TCP 80/443, then inspect journalctl -u caddy.'

status=$(curl -sS --max-time 5 --resolve "$domain:443:127.0.0.1" \
    -o /dev/null -w '%{http_code}' "https://$domain/telegram/web/")
[[ $status == 200 || $status == 404 ]] || die "Caddy returned HTTP $status for the WEB route."

install -m 0600 /dev/null "$link"
python3 - "$config" > "$link" <<'PY'
import base64
import sys
import tomllib
from urllib.parse import quote

with open(sys.argv[1], "rb") as config_file:
    config = tomllib.load(config_file)
vhost = config["web"]["vhosts"][0]
secret = bytes.fromhex(config["access"]["users"]["web-user"])
credential = base64.urlsafe_b64encode(b"\x70\xdd" + secret).decode().rstrip("=")
endpoint = quote(vhost["host"] + "/" + vhost["base_path"], safe="")
print(f"tg://webproxy?server={endpoint}&secret={credential}")
PY
complete=1
finish
