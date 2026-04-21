#!/bin/sh
# =============================================================================
#  Установщик системы селективной маршрутизации через AmneziaWG/WARP для Padavan
#  Версия 3.8 (стабильная) от 2026-04-21
#  Включает автообучение watchdog, поддержку IPv6, CONNMARK и ежедневный cron.
# =============================================================================

echo "=== Установка системы селективной маршрутизации (AmneziaWG + WARP) v3.8 ==="

# -----------------------------------------------------------------------------
# 1. Создание основного скрипта ipset_update.sh (v3.8)
# -----------------------------------------------------------------------------
cat > /etc/storage/ipset_update.sh << 'EOF_SCRIPT'
#!/bin/sh
IPSET_NAME="bypass_domains"
MARK_VALUE="0xca6c"
VPN_IFACE="wg0"
TABLE_ID=51
CACHE_FILE="/etc/storage/ipset_domains.cache"
IP_CACHE_FILE="/etc/storage/ipset_ips.cache"
LOG_FILE="/tmp/ipset_update.log"
CACHE_TTL=86400
PARALLEL=20
VPN_WAIT_TIMEOUT=120
VPN_TEST_HOST="1.1.1.1"

DOMAIN_SOURCES="
https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-raw.lst
https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/outside-raw.lst
"

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

log() { local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"; echo "$msg"; echo "$msg" >> "$LOG_FILE"; }
wait_for_vpn() {
    local elapsed=0
    log "Ожидаю $VPN_IFACE (макс ${VPN_WAIT_TIMEOUT}s)..."
    while ! ip link show "$VPN_IFACE" >/dev/null 2>&1; do
        [ $elapsed -ge $VPN_WAIT_TIMEOUT ] && log "ВНИМАНИЕ: $VPN_IFACE не поднялся" && return 1
        sleep 5; elapsed=$((elapsed+5))
    done
    log "$VPN_IFACE поднялся (${elapsed}s)"; return 0
}
check_vpn_works() {
    if curl --interface "$VPN_IFACE" --max-time 5 -s -o /dev/null -w "%{http_code}" http://1.1.1.1 | grep -qE "200|301|302"; then
        log "VPN OK (curl)"; return 0
    else
        log "ВНИМАНИЕ: VPN curl не проходит"; return 1
    fi
}
create_ipset() {
    modprobe ip_set 2>/dev/null; modprobe ip_set_hash_ip 2>/dev/null
    ipset list "$IPSET_NAME" >/dev/null 2>&1 || { log "Создаю ipset $IPSET_NAME"; ipset create "$IPSET_NAME" hash:ip hashsize 4096 maxelem 65536; }
    ipset create bypass_domains6 hash:ip family inet6 hashsize 1024 maxelem 65536 -exist 2>/dev/null
}
setup_policy_routing() {
    # IPv4
    ip rule del pref 5182 2>/dev/null
    ip rule add fwmark "$MARK_VALUE" lookup "$TABLE_ID" pref 5182
    ip route flush table "$TABLE_ID"
    ip route add default dev "$VPN_IFACE" table "$TABLE_ID"
    echo 0 > /proc/sys/net/ipv4/conf/"$VPN_IFACE"/rp_filter 2>/dev/null
    # IPv6
    ip -6 rule del pref 5182 2>/dev/null
    ip -6 rule add fwmark "$MARK_VALUE" lookup "$TABLE_ID" pref 5182
    ip -6 route flush table "$TABLE_ID" 2>/dev/null
    ip -6 route add default dev "$VPN_IFACE" table "$TABLE_ID" 2>/dev/null
    sysctl -w net.ipv6.conf."$VPN_IFACE".rp_filter=0 2>/dev/null
    log "Policy routing: fwmark $MARK_VALUE -> table $TABLE_ID (dev $VPN_IFACE, IPv4/IPv6)"
}
setup_iptables() {
    modprobe xt_set 2>/dev/null
    modprobe xt_CONNMARK 2>/dev/null
    # IPv4 MARK
    if ! iptables -t mangle -C PREROUTING -m set --match-set "$IPSET_NAME" dst -j MARK --set-mark "$MARK_VALUE" 2>/dev/null; then
        iptables -t mangle -A PREROUTING -m set --match-set "$IPSET_NAME" dst -j MARK --set-mark "$MARK_VALUE"
        log "Правило iptables MARK добавлено"
    fi
    # IPv4 CONNMARK (сохраняем метку в conntrack)
    if ! iptables -t mangle -C PREROUTING -m set --match-set "$IPSET_NAME" dst -j CONNMARK --set-mark "$MARK_VALUE" 2>/dev/null; then
        iptables -t mangle -A PREROUTING -m set --match-set "$IPSET_NAME" dst -j CONNMARK --set-mark "$MARK_VALUE"
        log "Правило CONNMARK (save) добавлено"
    fi
    # Восстанавливаем метку из conntrack
    if ! iptables -t mangle -C PREROUTING -m connmark --mark "$MARK_VALUE" -j CONNMARK --restore-mark 2>/dev/null; then
        iptables -t mangle -A PREROUTING -m connmark --mark "$MARK_VALUE" -j CONNMARK --restore-mark
        log "Правило CONNMARK (restore) добавлено"
    fi
    # IPv6 MARK
    if ! ip6tables -t mangle -C PREROUTING -m set --match-set bypass_domains6 dst -j MARK --set-mark "$MARK_VALUE" 2>/dev/null; then
        ip6tables -t mangle -A PREROUTING -m set --match-set bypass_domains6 dst -j MARK --set-mark "$MARK_VALUE"
        log "Правило ip6tables MARK добавлено"
    fi
}
resolve_one() { nslookup "$1" 8.8.8.8 2>/dev/null | awk '/^Address [0-9]+:/{print $NF}' | grep -E '^([0-9]+\.){3}[0-9]+$' | grep -v '^127\.' | grep -v '^0\.' > "/tmp/ipset_r/$1" 2>/dev/null; }
resolve_parallel() {
    local total i pids pid
    rm -rf /tmp/ipset_r; mkdir -p /tmp/ipset_r
    total=$(wc -l < "$1")
    log "Резолв $total доменов (параллельность $PARALLEL)..."
    i=0; pids=""
    while IFS= read -r domain; do
        [ -z "$domain" ] && continue
        while [ "$(echo $pids | wc -w)" -ge $PARALLEL ]; do
            new_pids=""
            for pid in $pids; do kill -0 "$pid" 2>/dev/null && new_pids="$new_pids $pid"; done
            pids="$new_pids"
            [ "$(echo $pids | wc -w)" -ge $PARALLEL ] && sleep 1
        done
        resolve_one "$domain" &
        pids="$pids $!"; i=$((i+1))
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
                echo "$ip" >> "$IP_CACHE_FILE.new"; ok=$((ok+1))
            done < "$f"
        else fail=$((fail+1)); fi
    done
    sort -u "$IP_CACHE_FILE.new" > "$IP_CACHE_FILE"
    rm -f "$IP_CACHE_FILE.new"; rm -rf /tmp/ipset_r
    log "IP добавлено=$ok, не резолвится=$fail"
    log "Уникальных IP: $(wc -l < $IP_CACHE_FILE)"
}
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
restore_from_cache() {
    [ -f "$IP_CACHE_FILE" ] && [ -s "$IP_CACHE_FILE" ] || return 1
    local count=0
    while IFS= read -r ip; do
        [ -z "$ip" ] && continue
        ipset add "$IPSET_NAME" "$ip" -exist 2>/dev/null && count=$((count+1))
    done < "$IP_CACHE_FILE"
    log "Восстановлено из кеша: $count IP"
}
cache_is_fresh() {
    [ -f "$CACHE_FILE" ] || return 1
    local mtime now age
    now=$(date +%s)
    mtime=$(date -r "$CACHE_FILE" +%s 2>/dev/null) || return 1
    age=$((now - mtime))
    [ $age -lt $CACHE_TTL ]
}

log "=== СТАРТ v3.8 ==="
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

chmod +x /etc/storage/ipset_update.sh

# -----------------------------------------------------------------------------
# 2. Настройка dnsmasq
# -----------------------------------------------------------------------------
cat >> /etc/storage/dnsmasq/dnsmasq.conf << 'EOF_DNSMASQ'

### Селективная маршрутизация: автоматическое добавление IP в bypass_domains
ipset=/discord.com/gateway.discord.gg/cdn.discordapp.com/discordapp.com/discord.gg/bypass_domains
ipset=/youtube.com/youtu.be/googlevideo.com/ytimg.com/youtube-nocookie.com/youtubekids.com/bypass_domains
ipset=/t.me/telegram.org/core.telegram.org/web.telegram.org/bypass_domains
EOF_DNSMASQ

kill -HUP $(pidof dnsmasq) 2>/dev/null

# -----------------------------------------------------------------------------
# 3. Добавление в автозагрузку
# -----------------------------------------------------------------------------
grep -q "ipset_update.sh" /etc/storage/started_script.sh || \
    echo "sleep 40 && sh /etc/storage/ipset_update.sh &" >> /etc/storage/started_script.sh

# -----------------------------------------------------------------------------
# 4. Создание улучшенного watchdog (v3.8) с автообучением
# -----------------------------------------------------------------------------
cat > /etc/storage/route_watchdog.sh << 'EOF_WATCHDOG'
#!/bin/sh
INTERVAL=15                   # Основной интервал проверки (сек)
ANALYZE_INTERVAL=60           # Интервал анализа неудачных соединений (сек)
LAST_ANALYZE=0

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

    # 5. Проверка CONNMARK save
    if ! iptables -t mangle -C PREROUTING -m set --match-set bypass_domains dst -j CONNMARK --set-mark 0xca6c 2>/dev/null; then
        iptables -t mangle -A PREROUTING -m set --match-set bypass_domains dst -j CONNMARK --set-mark 0xca6c
        echo "[$(date)] Watchdog: добавлено правило CONNMARK save" >> /tmp/route_watchdog.log
    fi

    # 6. Проверка CONNMARK restore
    if ! iptables -t mangle -C PREROUTING -m connmark --mark 0xca6c -j CONNMARK --restore-mark 2>/dev/null; then
        iptables -t mangle -A PREROUTING -m connmark --mark 0xca6c -j CONNMARK --restore-mark
        echo "[$(date)] Watchdog: добавлено правило CONNMARK restore" >> /tmp/route_watchdog.log
    fi

    # 7. Проверка ip6tables MARK
    if ! ip6tables -t mangle -C PREROUTING -m set --match-set bypass_domains6 dst -j MARK --set-mark 0xca6c 2>/dev/null; then
        ip6tables -t mangle -A PREROUTING -m set --match-set bypass_domains6 dst -j MARK --set-mark 0xca6c
        echo "[$(date)] Watchdog: добавлено правило ip6tables MARK" >> /tmp/route_watchdog.log
    fi

    # 8. Проверка IPv6 policy routing
    if ! ip -6 rule show | grep -q "5182.*fwmark 0xca6c lookup 51"; then
        ip -6 rule del pref 5182 2>/dev/null
        ip -6 rule add fwmark 0xca6c lookup 51 pref 5182
        ip -6 route replace default dev wg0 table 51
        echo "[$(date)] Watchdog: исправлен IPv6 policy routing" >> /tmp/route_watchdog.log
    fi

    # 9. Проверка наполненности ipset (если меньше 100 IP — запускаем основной скрипт)
    ENTRIES=$(ipset list bypass_domains 2>/dev/null | grep -oE 'Number of entries: [0-9]+' | awk '{print $NF}')
    if [ -n "$ENTRIES" ] && [ "$ENTRIES" -lt 100 ]; then
        echo "[$(date)] Watchdog: ipset почти пуст ($ENTRIES IP), запускаю ipset_update.sh" >> /tmp/route_watchdog.log
        sh /etc/storage/ipset_update.sh &
    fi

    # 10. АВТООБУЧЕНИЕ: анализ неудачных SYN-пакетов (TCP-блокировки)
    NOW=$(date +%s)
    if [ $(( NOW - LAST_ANALYZE )) -ge $ANALYZE_INTERVAL ]; then
        LAST_ANALYZE=$NOW
        # Ищем записи о SYN-пакетах к порту 443 в любом порядке
        dmesg | grep -E "DPT=443.*SYN|SYN.*DPT=443" | tail -30 | while read line; do
            DST_IP=$(echo "$line" | grep -oE 'DST=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | cut -d'=' -f2)
            if [ -n "$DST_IP" ] && ! ipset test bypass_domains "$DST_IP" 2>/dev/null; then
                ipset add bypass_domains "$DST_IP" -exist
                echo "[$(date)] Watchdog: Автоматически добавлен IP $DST_IP из неудачного соединения" >> /tmp/route_watchdog.log
            fi
        done
        dmesg -c > /dev/null 2>&1
    fi

    sleep $INTERVAL
done
EOF_WATCHDOG

chmod +x /etc/storage/route_watchdog.sh

# -----------------------------------------------------------------------------
# 5. Запуск watchdog в автозагрузке (с задержкой)
# -----------------------------------------------------------------------------
grep -q "route_watchdog.sh" /etc/storage/started_script.sh || \
    echo "( sleep 90 && /etc/storage/route_watchdog.sh & ) &" >> /etc/storage/started_script.sh

# -----------------------------------------------------------------------------
# 6. Настройка ежедневного cron
# -----------------------------------------------------------------------------
if [ -d /etc/storage/cron/crontabs ]; then
    CRON_FILE="/etc/storage/cron/crontabs/admin"
    grep -q "ipset_update.sh" "$CRON_FILE" 2>/dev/null || \
        echo "0 4 * * * sh /etc/storage/ipset_update.sh > /tmp/ipset_update_cron.log 2>&1" >> "$CRON_FILE"
    killall crond 2>/dev/null && crond
fi

# -----------------------------------------------------------------------------
# 7. Сохранение и первый запуск
# -----------------------------------------------------------------------------
mtd_storage.sh save

echo "=============================================="
echo "Установка v3.8 завершена. Запускаю первый резолв..."
echo "=============================================="
sh /etc/storage/ipset_update.sh