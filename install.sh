#!/bin/sh
# =============================================================================
#  Установщик системы селективной маршрутизации через AmneziaWG/WARP для Padavan
#  Версия 3.6 (финальная) от 2026-04-17
#  Автоматически настраивает ipset, dnsmasq, policy routing, watchdog и cron.
# =============================================================================

echo "=== Установка системы селективной маршрутизации (AmneziaWG + WARP) ==="

# -----------------------------------------------------------------------------
# 1. Создание основного скрипта ipset_update.sh (версия 3.6)
# -----------------------------------------------------------------------------
cat > /etc/storage/ipset_update.sh << 'EOF_SCRIPT'
#!/bin/sh
# =============================================================================
#  Скрипт селективной маршрутизации через AmneziaWG/WARP для Padavan
#  Версия 3.6
#  Выполняет резолв доменов из списков, заполняет ipset и настраивает
#  policy routing для направления трафика к заданным IP через VPN-туннель.
# =============================================================================

# ------------------------------ НАСТРОЙКИ ------------------------------------
IPSET_NAME="bypass_domains"          # Имя множества IP-адресов
MARK_VALUE="0xca6c"                  # Метка для маркировки пакетов
VPN_IFACE="wg0"                      # Имя интерфейса VPN (AmneziaWG)
TABLE_ID=51                          # Номер таблицы маршрутизации для VPN

CACHE_FILE="/etc/storage/ipset_domains.cache"   # Кеш списка доменов
IP_CACHE_FILE="/etc/storage/ipset_ips.cache"    # Кеш IP-адресов
LOG_FILE="/tmp/ipset_update.log"                # Лог-файл
CACHE_TTL=86400                      # Время жизни кеша (сутки)
PARALLEL=20                          # Количество параллельных потоков резолва
VPN_WAIT_TIMEOUT=120                 # Макс. время ожидания VPN (сек)
VPN_TEST_HOST="1.1.1.1"              # Хост для проверки работы VPN

# Список URL, откуда скачиваются списки доменов для селективной маршрутизации
DOMAIN_SOURCES="
https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-raw.lst
https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/outside-raw.lst
"

# Статические домены (гарантированно добавляются всегда)
STATIC_DOMAINS="
discord.com
gateway.discord.gg
cdn.discordapp.com
discordapp.com
discord.gg
youtube.com
youtu.be
googlevideo.com
ytimg.com
t.me
telegram.org
core.telegram.org
web.telegram.org
"

# ------------------------------ ФУНКЦИИ ---------------------------------------
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

# Ожидание появления VPN-интерфейса
wait_for_vpn() {
    local elapsed=0
    log "Ожидаю $VPN_IFACE (макс ${VPN_WAIT_TIMEOUT}s)..."
    while ! ip link show "$VPN_IFACE" >/dev/null 2>&1; do
        [ $elapsed -ge $VPN_WAIT_TIMEOUT ] && log "ВНИМАНИЕ: $VPN_IFACE не поднялся" && return 1
        sleep 5
        elapsed=$((elapsed+5))
    done
    log "$VPN_IFACE поднялся (${elapsed}s)"
    return 0
}

# Проверка прохождения трафика через туннель (используется curl, т.к. ping может блокироваться WARP)
check_vpn_works() {
    if curl --interface "$VPN_IFACE" --max-time 5 -s -o /dev/null -w "%{http_code}" http://1.1.1.1 | grep -qE "200|301|302"; then
        log "VPN OK (curl)"
        return 0
    else
        log "ВНИМАНИЕ: VPN curl не проходит"
        return 1
    fi
}

# Создание ipset, если его нет
create_ipset() {
    modprobe ip_set 2>/dev/null
    modprobe ip_set_hash_ip 2>/dev/null
    ipset list "$IPSET_NAME" >/dev/null 2>&1 || {
        log "Создаю ipset $IPSET_NAME"
        ipset create "$IPSET_NAME" hash:ip hashsize 4096 maxelem 65536
    }
}

# Настройка policy routing: помеченные пакеты отправляются в отдельную таблицу
setup_policy_routing() {
    # Удаляем старое правило и создаём новое
    ip rule del pref 5182 2>/dev/null
    ip rule add fwmark "$MARK_VALUE" lookup "$TABLE_ID" pref 5182
    ip route flush table "$TABLE_ID"
    ip route add default dev "$VPN_IFACE" table "$TABLE_ID"
    # Отключаем rp_filter для VPN-интерфейса (необходимо для обратного трафика)
    echo 0 > /proc/sys/net/ipv4/conf/"$VPN_IFACE"/rp_filter 2>/dev/null
    log "Policy routing: fwmark $MARK_VALUE -> table $TABLE_ID (dev $VPN_IFACE)"
}

# Добавление правила iptables для маркировки трафика
setup_iptables() {
    modprobe xt_set 2>/dev/null
    if ! iptables -t mangle -C PREROUTING -m set --match-set "$IPSET_NAME" dst -j MARK --set-mark "$MARK_VALUE" 2>/dev/null; then
        iptables -t mangle -A PREROUTING -m set --match-set "$IPSET_NAME" dst -j MARK --set-mark "$MARK_VALUE"
        log "Правило iptables добавлено"
    else
        log "Правило iptables уже существует"
    fi
}

# Резолв одного домена через 8.8.8.8
resolve_one() {
    nslookup "$1" 8.8.8.8 2>/dev/null \
        | awk '/^Address [0-9]+:/{print $NF}' \
        | grep -E '^([0-9]+\.){3}[0-9]+$' \
        | grep -v '^127\.' | grep -v '^0\.' \
        > "/tmp/ipset_r/$1" 2>/dev/null
}

# Параллельный резолв всех доменов из файла
resolve_parallel() {
    local total i pids pid
    rm -rf /tmp/ipset_r
    mkdir -p /tmp/ipset_r
    total=$(wc -l < "$1")
    log "Резолв $total доменов (параллельность $PARALLEL)..."

    i=0; pids=""
    while IFS= read -r domain; do
        [ -z "$domain" ] && continue
        # Ограничение количества одновременных процессов
        while [ "$(echo $pids | wc -w)" -ge $PARALLEL ]; do
            new_pids=""
            for pid in $pids; do
                kill -0 "$pid" 2>/dev/null && new_pids="$new_pids $pid"
            done
            pids="$new_pids"
            [ "$(echo $pids | wc -w)" -ge $PARALLEL ] && sleep 1
        done
        resolve_one "$domain" &
        pids="$pids $!"
        i=$((i+1))
        [ $((i % 200)) -eq 0 ] && log " Прогресс: $i/$total"
    done < "$1"
    wait
    log "Резолв завершён, собираю IP..."

    local ok=0 fail=0
    > "$IP_CACHE_FILE.new"
    for f in /tmp/ipset_r/*; do
        [ -f "$f" ] || continue
        if [ -s "$f" ]; then
            while IFS= read -r ip; do
                [ -z "$ip" ] && continue
                ipset add "$IPSET_NAME" "$ip" -exist 2>/dev/null
                echo "$ip" >> "$IP_CACHE_FILE.new"
                ok=$((ok+1))
            done < "$f"
        else
            fail=$((fail+1))
        fi
    done
    sort -u "$IP_CACHE_FILE.new" > "$IP_CACHE_FILE"
    rm -f "$IP_CACHE_FILE.new"
    rm -rf /tmp/ipset_r
    log "IP добавлено=$ok, не резолвится=$fail"
    log "Уникальных IP: $(wc -l < $IP_CACHE_FILE)"
}

# Скачивание списков доменов и обновление кеша
update_domains() {
    local tmp="/tmp/ipset_domains.tmp"
    > "$tmp"
    for url in $DOMAIN_SOURCES; do
        [ -z "$url" ] && continue
        log "Скачиваю: $url"
        if echo "$url" | grep -q '\.gz$'; then
            wget -q -O - "$url" 2>/dev/null | gunzip -c >> "$tmp" 2>/dev/null
        else
            wget -q -O - "$url" 2>/dev/null >> "$tmp"
        fi
    done
    echo "$STATIC_DOMAINS" >> "$tmp"
    sort -u "$tmp" | grep -E '^[a-zA-Z0-9]' > "$CACHE_FILE"
    rm -f "$tmp"
    log "Доменов: $(wc -l < $CACHE_FILE)"
    resolve_parallel "$CACHE_FILE"
}

# Восстановление ipset из кеша (после перезагрузки)
restore_from_cache() {
    [ -f "$IP_CACHE_FILE" ] && [ -s "$IP_CACHE_FILE" ] || return 1
    local count=0
    while IFS= read -r ip; do
        [ -z "$ip" ] && continue
        ipset add "$IPSET_NAME" "$ip" -exist 2>/dev/null && count=$((count+1))
    done < "$IP_CACHE_FILE"
    log "Восстановлено из кеша: $count IP"
}

# Проверка свежести кеша доменов
cache_is_fresh() {
    [ -f "$CACHE_FILE" ] || return 1
    local mtime now age
    now=$(date +%s)
    mtime=$(date -r "$CACHE_FILE" +%s 2>/dev/null) || return 1
    age=$((now - mtime))
    [ $age -lt $CACHE_TTL ]
}

# ------------------------------ ГЛАВНЫЙ БЛОК --------------------------------
log "=== СТАРТ v3.6 ==="

create_ipset

if wait_for_vpn; then
    setup_policy_routing
    check_vpn_works
    setup_iptables
else
    log "VPN не поднялся --- policy routing и MARK не включаю"
fi

if cache_is_fresh; then
    log "Кеш актуален --- восстанавливаю"
    restore_from_cache
else
    log "Обновляю списки"
    update_domains
fi

log "IP в ipset: $(ipset list $IPSET_NAME 2>/dev/null | grep -c '^[0-9]')"
log "=== КОНЕЦ ==="
EOF_SCRIPT

# -----------------------------------------------------------------------------
# 2. Права на выполнение основного скрипта
# -----------------------------------------------------------------------------
chmod +x /etc/storage/ipset_update.sh

# -----------------------------------------------------------------------------
# 3. Настройка dnsmasq для мгновенного добавления IP при DNS-запросах
# -----------------------------------------------------------------------------
cat >> /etc/storage/dnsmasq/dnsmasq.conf << 'EOF_DNSMASQ'

### Селективная маршрутизация: автоматическое добавление IP в bypass_domains
ipset=/discord.com/gateway.discord.gg/cdn.discordapp.com/discordapp.com/discord.gg/bypass_domains
ipset=/youtube.com/youtu.be/googlevideo.com/ytimg.com/youtube-nocookie.com/youtubekids.com/bypass_domains
ipset=/t.me/telegram.org/core.telegram.org/web.telegram.org/bypass_domains
EOF_DNSMASQ

kill -HUP $(pidof dnsmasq) 2>/dev/null

# -----------------------------------------------------------------------------
# 4. Добавление основного скрипта в автозагрузку (с задержкой 40 сек)
# -----------------------------------------------------------------------------
grep -q "ipset_update.sh" /etc/storage/started_script.sh || {
    echo "sleep 40 && sh /etc/storage/ipset_update.sh &" >> /etc/storage/started_script.sh
}

# -----------------------------------------------------------------------------
# 5. Создание и настройка сторожевого скрипта (watchdog)
# -----------------------------------------------------------------------------
cat > /etc/storage/route_watchdog.sh << 'EOF_WATCHDOG'
#!/bin/sh
INTERVAL=15

while true; do
    # 1. Проверка ip rule (без "not")
    if ! ip rule show | grep "5182" | grep -qv "not"; then
        ip rule del pref 5182 2>/dev/null
        ip rule add fwmark 0xca6c lookup 51 pref 5182
        echo "[$(date)] Watchdog: исправлено ip rule" >> /tmp/route_watchdog.log
    fi

    # 2. Проверка таблицы 51
    if ! ip route show table 51 | grep -q "default dev wg0"; then
        ip route replace default dev wg0 table 51
        echo "[$(date)] Watchdog: исправлен маршрут в table 51" >> /tmp/route_watchdog.log
    fi

    # 3. Проверка rp_filter
    if [ "$(sysctl -n net.ipv4.conf.wg0.rp_filter 2>/dev/null)" != "0" ]; then
        echo 0 > /proc/sys/net/ipv4/conf/wg0/rp_filter
        echo "[$(date)] Watchdog: исправлен rp_filter" >> /tmp/route_watchdog.log
    fi

    # 4. Проверка правила iptables MARK
    if ! iptables -t mangle -C PREROUTING -m set --match-set bypass_domains dst -j MARK --set-mark 0xca6c 2>/dev/null; then
        iptables -t mangle -A PREROUTING -m set --match-set bypass_domains dst -j MARK --set-mark 0xca6c
        echo "[$(date)] Watchdog: добавлено правило iptables MARK" >> /tmp/route_watchdog.log
    fi

    # 5. Проверка количества IP в ipset (если меньше 100 — запускаем основной скрипт)
    ENTRIES=$(ipset list bypass_domains 2>/dev/null | grep -oE 'Number of entries: [0-9]+' | awk '{print $NF}')
    if [ -n "$ENTRIES" ] && [ "$ENTRIES" -lt 100 ]; then
        echo "[$(date)] Watchdog: ipset почти пуст ($ENTRIES IP), запускаю ipset_update.sh" >> /tmp/route_watchdog.log
        sh /etc/storage/ipset_update.sh &
    fi

    sleep $INTERVAL
done
EOF_WATCHDOG

chmod +x /etc/storage/route_watchdog.sh

# -----------------------------------------------------------------------------
# 6. Добавление сторожевого скрипта в автозагрузку (с задержкой 90 сек)
# -----------------------------------------------------------------------------
grep -q "route_watchdog.sh" /etc/storage/started_script.sh || {
    echo "( sleep 90 && /etc/storage/route_watchdog.sh & ) &" >> /etc/storage/started_script.sh
}

# -----------------------------------------------------------------------------
# 7. Настройка ежедневного cron-задания на 04:00
# -----------------------------------------------------------------------------
if [ -d /etc/storage/cron/crontabs ]; then
    CRON_FILE="/etc/storage/cron/crontabs/admin"
    grep -q "ipset_update.sh" "$CRON_FILE" 2>/dev/null || \
        echo "0 4 * * * sh /etc/storage/ipset_update.sh > /tmp/ipset_update_cron.log 2>&1" >> "$CRON_FILE"
    killall crond 2>/dev/null && crond
fi

# -----------------------------------------------------------------------------
# 8. Сохранение всех настроек и первый запуск
# -----------------------------------------------------------------------------
mtd_storage.sh save

echo ""
echo "=============================================="
echo "Установка завершена! Запускаю первый резолв..."
echo "=============================================="
sh /etc/storage/ipset_update.sh
