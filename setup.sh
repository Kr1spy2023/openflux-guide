#!/bin/bash
# setup.sh — ставит OpenFlux с нуля: Go, репозиторий, команду управления,
# сетевое правило, защиту от переполнения диска логами.
# Запуск: sudo bash setup.sh
set -e

REPO_DIR="/root/openflux"
REPO_URL="https://github.com/p1neappleXpress/OpenFlux.git"
SECRETS="/root/openflux-secrets"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
    echo "Запусти от root: sudo bash setup.sh"
    exit 1
fi

echo "== 1/8: системные пакеты =="
apt-get update -y
apt-get install -y git curl snapd iptables cron

echo "== 2/8: Go =="
export PATH="$PATH:/snap/bin"
if ! command -v go > /dev/null 2>&1; then
    snap install go --classic
fi
go version

echo "== 3/8: код проекта =="
if [ -d "$REPO_DIR/.git" ]; then
    echo "Репозиторий уже есть, обновляю..."
    git -C "$REPO_DIR" fetch --quiet origin main
    git -C "$REPO_DIR" checkout --quiet --force main
    git -C "$REPO_DIR" reset --quiet --hard origin/main
else
    git clone --quiet "$REPO_URL" "$REPO_DIR"
fi
cd "$REPO_DIR"
go build -o openflux .
chmod +x openflux
git rev-parse HEAD > "$REPO_DIR/.built-commit"

echo "== 4/8: папка секретов =="
mkdir -p "$SECRETS"
chmod 700 "$SECRETS"
if [ ! -s "$SECRETS/encryption-key" ]; then
    head -c 256 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 44 > "$SECRETS/encryption-key"
    chmod 600 "$SECRETS/encryption-key"
    echo "Сгенерирован новый ключ шифрования:"
    cat "$SECRETS/encryption-key"
    echo
    echo "Сохрани его — этот же ключ нужен на клиентах."
else
    echo "Ключ шифрования уже существует, оставляю как есть."
fi

echo "== 5/8: команды управления =="
install -m 755 "$HERE/openflux-ctl" /usr/local/bin/openflux-ctl
install -m 755 "$HERE/openflux-deploy" /usr/local/bin/openflux-deploy

echo "== 6/8: сетевое правило (сброс исходящих RST) =="
cat > /usr/local/sbin/openflux-firewall <<'EOF'
#!/bin/bash
set -e
iptables -C OUTPUT -p tcp --tcp-flags RST RST -j DROP 2>/dev/null || \
  iptables -A OUTPUT -p tcp --tcp-flags RST RST -j DROP
if command -v iptables-legacy >/dev/null 2>&1 && iptables-legacy -L -n >/dev/null 2>&1; then
  iptables-legacy -C OUTPUT -p tcp --tcp-flags RST RST -j DROP 2>/dev/null || \
    iptables-legacy -A OUTPUT -p tcp --tcp-flags RST RST -j DROP
fi
EOF
chmod 755 /usr/local/sbin/openflux-firewall

cat > /etc/systemd/system/firewall-openflux.service <<'EOF'
[Unit]
Description=OpenFlux firewall rule (drop outgoing RST)
Before=network-pre.target
Wants=network-pre.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/openflux-firewall
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now firewall-openflux.service

echo "== 7/8: защита от переполнения диска логами =="
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/openflux.conf <<'EOF'
[Journal]
SystemMaxUse=150M
EOF
systemctl restart systemd-journald

cat > /etc/logrotate.d/openflux-deploy <<'EOF'
/var/log/openflux-deploy.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    maxsize 50M
}
EOF

echo "== 8/8: автообновление по расписанию =="
openflux-ctl auto on 10 > /dev/null

echo ""
echo "======================================================"
echo " Установка завершена."
echo "======================================================"
echo "Дальше: добавь хотя бы одну ноду, например:"
echo "  openflux-ctl add yandex https://disk.yandex.ru/i/XXXXXXXXXXXX"
echo ""
echo "Полный список команд:"
echo "  openflux-ctl help"
echo ""
echo "Проверка состояния всей системы:"
echo "  openflux-ctl check"
