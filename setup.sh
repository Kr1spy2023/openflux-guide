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

# Функция определения и переключения на самую свежую ветку
sync_to_latest_branch() {
    cd "$REPO_DIR"
    echo "Проверяю ветки на GitHub (main vs release/X.Y.Z)..."

    # 1. Ищем последнюю релизную ветку release/X.Y.Z
    set +e
    local rel_out latest_rel
    rel_out=$(git ls-remote --heads "$REPO_URL" 'refs/heads/release/*' 2>/dev/null | grep -E 'refs/heads/release/[0-9]+\.[0-9]+\.[0-9]+$')
    if [ -n "$rel_out" ]; then
        latest_rel=$(echo "$rel_out" | awk -F'refs/heads/' '{print $2}' | sort -V | tail -n 1)
    else
        latest_rel=""
    fi
    set -e

    # 2. Фетчим main и получаем время последнего коммита
    git fetch --quiet origin main
    local main_time release_time target_branch="main"
    main_time=$(git log -1 --format=%ct origin/main 2>/dev/null || echo 0)

    # 3. Сравниваем время коммита main и релизной ветки
    if [ -n "$latest_rel" ]; then
        if git fetch --quiet origin "$latest_rel" 2>/dev/null; then
            release_time=$(git log -1 --format=%ct "origin/$latest_rel" 2>/dev/null || echo 0)
            if [ "$release_time" -gt "$main_time" ]; then
                target_branch="$latest_rel"
                echo "Найдена более свежая релизная ветка: $target_branch"
            else
                echo "Ветка main свежее ($latest_rel устарела). Выбираем main."
            fi
        fi
    fi

    echo "Переключаюсь на ветку: $target_branch"
    git checkout --quiet --force "$target_branch" 2>/dev/null || git checkout --quiet -B "$target_branch" "origin/$target_branch"
    git reset --quiet --hard "origin/$target_branch"
}

if [ -d "$REPO_DIR/.git" ]; then
    echo "Репозиторий уже существует. Проверяю и обновляю до последней версии..."
    sync_to_latest_branch
else
    echo "Репозиторий не найден. Клонирую заново..."
    git clone --quiet "$REPO_URL" "$REPO_DIR"
    sync_to_latest_branch
fi

# Сборка бинарника
cd "$REPO_DIR"
echo "Собираю (go build)..."
go build -o openflux .
chmod +x openflux
git rev-parse HEAD > "$REPO_DIR/.built-commit"
echo "Успешно собрана версия $(git rev-parse --short HEAD) ($(git rev-parse --abbrev-ref HEAD))"

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
