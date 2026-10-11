#!/usr/bin/env bash
# =====================================================================
#  내 토렌트 (MyTorrent) 설치 스크립트
#  - Ubuntu 24.04 (또는 22.04) 클라우드 서버에서 root 로 실행:
#        bash install.sh
#  - 다시 실행하면 업데이트만 하고, 비밀번호는 그대로 유지됩니다.
# =====================================================================
set -euo pipefail

APP=/opt/mytorrent
DATA=/srv/torrents
STATE=/var/lib/mytorrent
ENVF=/etc/mytorrent.env
SVC=mytorrent
TPORT=6881

say()  { printf '\n\033[1;32m▶ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "root 권한이 필요해요. 'sudo bash install.sh' 로 다시 실행하세요."; exit 1
fi
if ! command -v apt-get >/dev/null; then
  echo "Ubuntu/Debian 서버에서만 동작해요."; exit 1
fi

say "1/6 필요한 프로그램 설치 (1~3분)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y -qq
apt-get install -y -qq python3 python3-libtorrent python3-flask python3-waitress curl ca-certificates >/dev/null
if ! apt-get install -y -qq caddy >/dev/null 2>&1; then
  # 22.04 처럼 기본 저장소에 caddy 가 없는 경우 공식 저장소 추가
  apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https gnupg >/dev/null
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -y -qq
  apt-get install -y -qq caddy >/dev/null
fi
python3 -c "import libtorrent, flask, waitress" || { echo "파이썬 패키지 설치 실패"; exit 1; }

say "2/6 사용자와 폴더 준비"
id -u mytorrent >/dev/null 2>&1 || useradd --system --home "$STATE" --shell /usr/sbin/nologin mytorrent
mkdir -p "$APP/static" "$DATA" "$STATE"
chown -R mytorrent:mytorrent "$DATA" "$STATE"

say "3/6 앱 파일 설치"
#__FILES__
chmod 644 "$APP"/app.py "$APP"/static/*

say "4/6 비밀번호와 서비스 설정"
if [ -f "$ENVF" ] && grep -q '^MT_PASSWORD=' "$ENVF"; then
  echo "기존 비밀번호를 그대로 사용해요."
else
  PW="${MT_PASSWORD:-$(python3 -c "import secrets;print(''.join(secrets.choice('abcdefghjkmnpqrstuvwxyz23456789') for _ in range(12)))")}"
  SECRET="$(python3 -c 'import secrets;print(secrets.token_hex(32))')"
  umask 077
  cat > "$ENVF" <<EOF
MT_PASSWORD=$PW
MT_SECRET_KEY=$SECRET
MT_DOWNLOAD_DIR=$DATA
MT_STATE_DIR=$STATE
MT_TORRENT_PORT=$TPORT
MT_HTTP_HOST=127.0.0.1
MT_HTTP_PORT=8080
EOF
  umask 022
fi
chown root:mytorrent "$ENVF"; chmod 640 "$ENVF"

cat > /etc/systemd/system/$SVC.service <<EOF
[Unit]
Description=MyTorrent (personal torrent downloader)
After=network-online.target
Wants=network-online.target

[Service]
User=mytorrent
Group=mytorrent
EnvironmentFile=$ENVF
WorkingDirectory=$APP
ExecStart=/usr/bin/python3 $APP/app.py
Restart=always
RestartSec=3
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=$DATA $STATE

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now $SVC >/dev/null 2>&1
systemctl restart $SVC

say "5/6 HTTPS 주소 만들기"
IP="$(curl -4 -fsS --max-time 8 https://api.ipify.org || curl -4 -fsS --max-time 8 https://ifconfig.me || true)"
if [ -z "$IP" ]; then
  IP="$(hostname -I | awk '{print $1}')"
  warn "공인 IP 를 자동으로 찾지 못했어요. ($IP 로 진행)"
fi
DOMAIN="${MT_DOMAIN:-${IP//./-}.sslip.io}"
cat > /etc/caddy/Caddyfile <<EOF
$DOMAIN {
    encode gzip
    reverse_proxy 127.0.0.1:8080
}
EOF
systemctl enable caddy >/dev/null 2>&1 || true
systemctl restart caddy

say "6/6 방화벽 열기 (80, 443, $TPORT)"
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
  ufw allow $TPORT/tcp >/dev/null; ufw allow $TPORT/udp >/dev/null
fi
# 오라클 클라우드 우분투 이미지는 iptables 로 막혀 있음 → 허용 규칙 추가
if iptables -S INPUT 2>/dev/null | grep -q -- '-j REJECT'; then
  for rule in "-p tcp --dport 80" "-p tcp --dport 443" "-p tcp --dport $TPORT" "-p udp --dport $TPORT"; do
    # shellcheck disable=SC2086
    iptables -C INPUT $rule -j ACCEPT 2>/dev/null || iptables -I INPUT 1 $rule -j ACCEPT
  done
  command -v netfilter-persistent >/dev/null && netfilter-persistent save >/dev/null 2>&1 || true
fi

sleep 3
PW_NOW="$(grep '^MT_PASSWORD=' "$ENVF" | cut -d= -f2-)"
if systemctl is-active --quiet $SVC; then OK="정상 실행 중"; else OK="실행 실패 → journalctl -u $SVC 확인"; fi

cat <<EOF

=====================================================
  설치 완료!  ($OK)

  아이폰 사파리에서 열 주소:
      https://$DOMAIN

  비밀번호:
      $PW_NOW

  * 처음 접속은 HTTPS 인증서 발급 때문에 30초쯤 걸릴 수 있어요.
  * 안 열리면 클라우드 콘솔의 '보안 그룹/방화벽'에서
    TCP 80, 443 과 TCP/UDP $TPORT 를 열어 주세요.
  * 비밀번호 다시 보기:  grep PASSWORD $ENVF
=====================================================
EOF
