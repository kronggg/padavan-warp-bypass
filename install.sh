#!/bin/sh
# =============================================================================
#  Установщик системы селективной маршрутизации через AmneziaWG/WARP для Padavan
#  Версия 3.10.9-beta (финальная, с поддержкой IPv6)
# =============================================================================

echo "=== Установка системы селективной маршрутизации (AmneziaWG + WARP) v3.10.9-beta ==="

# -----------------------------------------------------------------------------
# 1. Создание основного скрипта ipset_update.sh
# -----------------------------------------------------------------------------
cat > /etc/storage/ipset_update.sh << 'EOF_SCRIPT'
#!/bin/sh
# -----------------------------------------------------------------------------
# Блокировка повторного запуска
# -----------------------------------------------------------------------------
LOCK_FILE="/tmp/ipset_update.lock"
if [ -f "$LOCK_FILE" ]; then
    echo "[$(date)] Скрипт уже выполняется, завершаюсь." >> /tmp/ipset_update.log
    exit 0
fi
touch "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# -----------------------------------------------------------------------------
# Настройки
# -----------------------------------------------------------------------------
IPSET_NAME="bypass_nets"
IPSET_TMP="${IPSET_NAME}_tmp"
IPSET6_NAME="bypass_nets6"
IPSET6_TMP="${IPSET6_NAME}_tmp"
VPN_IFACE="wg0"
TABLE_ID=51
MARK_VALUE="0xca6c"
LOG_FILE="/tmp/ipset_update.log"
LEARNED_CACHE="/etc/storage/learned_ips.cache"

CIDR_SOURCES="
https://raw.githubusercontent.com/you-oops-dev/resolving-public/main/unblock_suite_ip_ipset.txt
https://raw.githubusercontent.com/you-oops-dev/resolving-public/main/unblock_suite_ip.txt
https://antifilter.download/list/subnet.lst
https://raw.githubusercontent.com/runetfreedom/russia-blocked-geoip/main/text/ru-blocked.txt
https://raw.githubusercontent.com/1andrevich/Re-filter-lists/main/cidr.txt
https://raw.githubusercontent.com/1andrevich/Re-filter-lists/main/ipsum.lst
https://raw.githubusercontent.com/lord-alfred/ipranges/main/google/ipv4_merged.txt
https://raw.githubusercontent.com/lord-alfred/ipranges/main/cloudflare/ipv4_merged.txt
https://raw.githubusercontent.com/lord-alfred/ipranges/main/telegram/ipv4_merged.txt
https://raw.githubusercontent.com/lord-alfred/ipranges/main/facebook/ipv4_merged.txt
https://raw.githubusercontent.com/lord-alfred/ipranges/main/twitter/ipv4_merged.txt
https://raw.githubusercontent.com/lord-alfred/ipranges/main/amazon/ipv4_merged.txt
https://raw.githubusercontent.com/lord-alfred/ipranges/main/microsoft/ipv4_merged.txt
"
CIDR6_SOURCES="
https://raw.githubusercontent.com/lord-alfred/ipranges/main/telegram/ipv6_merged.txt
https://raw.githubusercontent.com/lord-alfred/ipranges/main/facebook/ipv6_merged.txt
https://raw.githubusercontent.com/lord-alfred/ipranges/main/google/ipv6_merged.txt
https://raw.githubusercontent.com/lord-alfred/ipranges/main/cloudflare/ipv6_merged.txt
"
MIN_ENTRIES=100

log() { local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"; echo "$msg"; echo "$msg" >> "$LOG_FILE"; }

# -----------------------------------------------------------------------------
# Ожидание полной готовности сети и VPN-туннеля
# -----------------------------------------------------------------------------
wait_for_network() {
    log "Ожидаю доступность WAN (макс 120s)..."
    local wan_ok=0
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        if ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1 || wget -q --spider http://cp.cloudflare.com 2>/dev/null; then
            wan_ok=1
            break
        fi
        sleep 10
    done
    if [ $wan_ok -eq 0 ]; then
        log "ОШИБКА: WAN не доступен после 120 секунд"
        return 1
    fi
    log "WAN доступен"

    log "Ожидаю VPN-интерфейс $VPN_IFACE и handshake (макс 120s)..."
    local vpn_ok=0
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        if ip link show "$VPN_IFACE" >/dev/null 2>&1; then
            if awg show "$VPN_IFACE" 2>/dev/null | grep -q "latest handshake"; then
                vpn_ok=1
                break
            elif wg show "$VPN_IFACE" 2>/dev/null | grep -q "latest handshake"; then
                vpn_ok=1
                break
            fi
        fi
        sleep 10
    done
    if [ $vpn_ok -eq 0 ]; then
        log "ОШИБКА: VPN handshake не установлен после 120 секунд"
        return 1
    fi
    log "$VPN_IFACE готов, handshake установлен"

    # Автоопределение параметров
    TABLE_ID=$(ip rule show | grep -E "fwmark 0x[0-9a-f]+.*lookup [0-9]+" | head -1 | sed -E 's/.*lookup ([0-9]+).*/\1/')
    [ -z "$TABLE_ID" ] && TABLE_ID=51

    if command -v wg >/dev/null 2>&1; then
        MARK_VALUE=$(wg show "$VPN_IFACE" fwmark 2>/dev/null | awk '{print $2}')
    elif command -v awg >/dev/null 2>&1; then
        MARK_VALUE=$(awg show "$VPN_IFACE" fwmark 2>/dev/null | awk '{print $2}')
    fi
    if [ -z "$MARK_VALUE" ]; then
        MARK_VALUE=$(ip rule show | grep -E "fwmark 0x[0-9a-f]+.*lookup $TABLE_ID" | head -1 | sed -E 's/.*fwmark (0x[0-9a-f]+).*/\1/')
    fi
    [ -z "$MARK_VALUE" ] && MARK_VALUE="0xca6c"

    log "Определены параметры: TABLE_ID=$TABLE_ID, MARK_VALUE=$MARK_VALUE"
    return 0
}

# -----------------------------------------------------------------------------
# Настройка policy routing
# -----------------------------------------------------------------------------
setup_policy_routing() {
    ip rule del pref 5182 2>/dev/null
    ip rule add fwmark "$MARK_VALUE" lookup "$TABLE_ID" pref 5182
    ip route flush table "$TABLE_ID"
    ip route add default dev "$VPN_IFACE" table "$TABLE_ID"
    # Отключаем rp_filter для VPN-интерфейса (необходимо для обратного трафика)
    echo 0 > /proc/sys/net/ipv4/conf/"$VPN_IFACE"/rp_filter 2>/dev/null
    ip -6 rule del pref 5182 2>/dev/null
    ip -6 rule add fwmark "$MARK_VALUE" lookup "$TABLE_ID" pref 5182
    ip -6 route flush table "$TABLE_ID" 2>/dev/null
    ip -6 route add default dev "$VPN_IFACE" table "$TABLE_ID" 2>/dev/null
    sysctl -w net.ipv6.conf."$VPN_IFACE".rp_filter=0 2>/dev/null
    log "Policy routing: fwmark $MARK_VALUE -> table $TABLE_ID (dev $VPN_IFACE)"
}

# -----------------------------------------------------------------------------
# Настройка правил iptables
# -----------------------------------------------------------------------------
setup_iptables() {
    modprobe ip_set_hash_net 2>/dev/null
    modprobe xt_set 2>/dev/null
    modprobe xt_CONNMARK 2>/dev/null

    if ! ipset list "$IPSET_NAME" >/dev/null 2>&1; then
        ipset create "$IPSET_NAME" hash:net maxelem 100000 2>/dev/null
    fi

    iptables -t mangle -D PREROUTING -m set --match-set "$IPSET_NAME" dst -j MARK --set-mark "$MARK_VALUE" 2>/dev/null
    iptables -t mangle -D PREROUTING -m set --match-set "$IPSET_NAME" dst -j CONNMARK --set-mark "$MARK_VALUE" 2>/dev/null
    iptables -t mangle -D PREROUTING -m connmark --mark "$MARK_VALUE" -j CONNMARK --restore-mark 2>/dev/null

    iptables -t mangle -A PREROUTING -m set --match-set "$IPSET_NAME" dst -j MARK --set-mark "$MARK_VALUE"
    iptables -t mangle -A PREROUTING -m set --match-set "$IPSET_NAME" dst -j CONNMARK --set-mark "$MARK_VALUE"
    iptables -t mangle -A PREROUTING -m connmark --mark "$MARK_VALUE" -j CONNMARK --restore-mark

    log "Правила iptables для $IPSET_NAME добавлены"
	
    # IPv6
    modprobe ip6_set 2>/dev/null
    modprobe ip6_set_hash_net 2>/dev/null
    if ! ipset list "$IPSET6_NAME" >/dev/null 2>&1; then
        ipset create "$IPSET6_NAME" hash:net family inet6 maxelem 50000 2>/dev/null
    fi
    ip6tables -t mangle -D PREROUTING -m set --match-set "$IPSET6_NAME" dst -j MARK --set-mark "$MARK_VALUE" 2>/dev/null
    ip6tables -t mangle -D PREROUTING -m set --match-set "$IPSET6_NAME" dst -j CONNMARK --set-mark "$MARK_VALUE" 2>/dev/null
    ip6tables -t mangle -A PREROUTING -m set --match-set "$IPSET6_NAME" dst -j MARK --set-mark "$MARK_VALUE"
    ip6tables -t mangle -A PREROUTING -m set --match-set "$IPSET6_NAME" dst -j CONNMARK --set-mark "$MARK_VALUE"
	
    log "Правила ip6tables для $IPSET6_NAME добавлены"
}

# -----------------------------------------------------------------------------
# Обновление ipset из CIDR-списков
# -----------------------------------------------------------------------------
update_ipset() {
    log "=== ОБНОВЛЕНИЕ IPSET ИЗ CIDR-СПИСКОВ ==="
    local tmp_all="/tmp/cidr_all_raw.txt"
    > "$tmp_all"

    for url in $CIDR_SOURCES; do
        [ -z "$url" ] && continue
        log "Скачиваю: $url"
        wget -q -O - "$url" 2>/dev/null >> "$tmp_all"
    done

    local tmp_clean="/tmp/cidr_clean.txt"
    > "$tmp_clean"
    grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$tmp_all" 2>/dev/null | sort -u > "$tmp_clean"
    local count=$(wc -l < "$tmp_clean" 2>/dev/null)
    [ -z "$count" ] && count=0
    log "Найдено уникальных подсетей: $count"

    if [ "$count" -lt "$MIN_ENTRIES" ]; then
        log "ОШИБКА: слишком мало подсетей ($count), обновление прервано"
        rm -f "$tmp_all" "$tmp_clean"
        return 1
    fi

    modprobe ip_set_hash_net 2>/dev/null
    ipset create "$IPSET_TMP" hash:net maxelem 100000 2>/dev/null
    if [ $? -ne 0 ]; then
        log "ОШИБКА: не удалось создать временный ipset"
        rm -f "$tmp_all" "$tmp_clean"
        return 1
    fi

    log "Импортирую подсети во временный ipset..."
    [ -f "$tmp_clean" ] || return 1
    while read cidr; do
        [ -z "$cidr" ] && continue
        ipset add "$IPSET_TMP" "$cidr" -exist 2>/dev/null
    done < "$tmp_clean"

    ipset swap "$IPSET_NAME" "$IPSET_TMP" 2>/dev/null || {
        ipset destroy "$IPSET_NAME" 2>/dev/null
        ipset rename "$IPSET_TMP" "$IPSET_NAME"
    }
    ipset destroy "$IPSET_TMP" 2>/dev/null

    # Сохраняем исходный CIDR-список для быстрого восстановления
    cp "$tmp_clean" /etc/storage/bypass_nets.cidr
    rm -f "$tmp_all" "$tmp_clean"
    log "Обновление завершено. Записей в $IPSET_NAME: $(ipset list $IPSET_NAME | grep -oE 'Number of entries: [0-9]+' | awk '{print $4}')"
    return 0
}

# -----------------------------------------------------------------------------
# Обновление ipset6 из IPv6 CIDR-списков
# -----------------------------------------------------------------------------
update_ipset6() {
    log "=== ОБНОВЛЕНИЕ IPv6 IPSET ==="
    local tmp6="/tmp/cidr6_raw.txt"
    > "$tmp6"
    for url in $CIDR6_SOURCES; do
        [ -z "$url" ] && continue
        log "Скачиваю IPv6: $url"
        wget -q -O - "$url" 2>/dev/null >> "$tmp6"
    done
    local tmp6_clean="/tmp/cidr6_clean.txt"
    > "$tmp6_clean"
    grep -E '^[0-9a-f:]+/[0-9]+$' "$tmp6" 2>/dev/null | sort -u > "$tmp6_clean"
    local count6=$(wc -l < "$tmp6_clean" 2>/dev/null)
    [ -z "$count6" ] && count6=0
    log "Найдено уникальных IPv6 подсетей: $count6"

    if [ "$count6" -gt 0 ]; then
        ipset create "$IPSET6_TMP" hash:net family inet6 maxelem 50000 2>/dev/null
        if [ $? -eq 0 ]; then
            while read cidr6; do
                [ -z "$cidr6" ] && continue
                ipset add "$IPSET6_TMP" "$cidr6" -exist 2>/dev/null
            done < "$tmp6_clean"
            ipset swap "$IPSET6_NAME" "$IPSET6_TMP" 2>/dev/null || {
                ipset destroy "$IPSET6_NAME" 2>/dev/null
                ipset rename "$IPSET6_TMP" "$IPSET6_NAME"
            }
            ipset destroy "$IPSET6_TMP" 2>/dev/null
        fi
    fi
    cp "$tmp6_clean" /etc/storage/bypass_nets6.cidr 2>/dev/null
    rm -f "$tmp6" "$tmp6_clean"
    log "IPv6 обновление завершено"
}

# -----------------------------------------------------------------------------
# Восстановление выученных IP
# -----------------------------------------------------------------------------
restore_learned() {
    [ -f "$LEARNED_CACHE" ] || return 0
    local count=0
    while read ip; do
        [ -z "$ip" ] && continue
        ipset add "$IPSET_NAME" "$ip" -exist 2>/dev/null && count=$((count+1))
    done < "$LEARNED_CACHE"
    log "Восстановлено выученных IP: $count"
}

# -----------------------------------------------------------------------------
# Главный блок
# -----------------------------------------------------------------------------
log "=== СТАРТ v3.10.9-beta ==="
if wait_for_network; then
    setup_policy_routing
    setup_iptables

    # Быстрое восстановление из локального CIDR-списка
    if [ -f /etc/storage/bypass_nets.cidr ]; then
        cidr_count=$(wc -l < /etc/storage/bypass_nets.cidr 2>/dev/null)
        if [ "$cidr_count" -ge "$MIN_ENTRIES" ]; then
            modprobe ip_set_hash_net 2>/dev/null
            log "Быстрое восстановление ipset из CIDR-списка ($cidr_count подсетей)..."
            {
                echo "create $IPSET_TMP hash:net maxelem 100000"
                sed "s/^/add $IPSET_TMP /" /etc/storage/bypass_nets.cidr
            } | ipset restore 2>/dev/null
            if [ $? -eq 0 ]; then
                ipset swap "$IPSET_NAME" "$IPSET_TMP" 2>/dev/null || {
                    ipset destroy "$IPSET_NAME" 2>/dev/null
                    ipset rename "$IPSET_TMP" "$IPSET_NAME"
                }
                ipset destroy "$IPSET_TMP" 2>/dev/null
                log "ipset восстановлен, пропускаю полное обновление"
            else
                log "Ошибка восстановления, запускаю полное обновление"
                update_ipset
            fi
        else
            log "CIDR-список повреждён, запускаю полное обновление"
            update_ipset
        fi
    else
        update_ipset
    fi

    # Быстрое восстановление IPv6 из CIDR-файла
    if [ -f /etc/storage/bypass_nets6.cidr ]; then
        cidr6_count=$(wc -l < /etc/storage/bypass_nets6.cidr 2>/dev/null)
        if [ "$cidr6_count" -gt 0 ]; then
            modprobe ip6_set_hash_net 2>/dev/null
            log "Быстрое восстановление ipset6 из CIDR-списка ($cidr6_count подсетей)..."
            {
                echo "create $IPSET6_TMP hash:net family inet6 maxelem 50000"
                sed "s/^/add $IPSET6_TMP /" /etc/storage/bypass_nets6.cidr
            } | ipset restore 2>/dev/null
            if [ $? -eq 0 ]; then
                ipset swap "$IPSET6_NAME" "$IPSET6_TMP" 2>/dev/null || {
                    ipset destroy "$IPSET6_NAME" 2>/dev/null
                    ipset rename "$IPSET6_TMP" "$IPSET6_NAME"
                }
                ipset destroy "$IPSET6_TMP" 2>/dev/null
                log "ipset6 восстановлен"
            fi
        fi
    fi

    # Если ipset6 всё ещё пуст — загружаем подсети
    entries6=$(ipset list "$IPSET6_NAME" 2>/dev/null | grep -oE 'Number of entries: [0-9]+' | awk '{print $4}')
    if [ -z "$entries6" ] || [ "$entries6" -lt 10 ]; then
        log "ipset6 содержит $entries6 записей, запускаю обновление IPv6"
        update_ipset6
    fi

    restore_learned
else
    log "КРИТИЧЕСКАЯ ОШИБКА: сеть или VPN не готовы, завершаюсь"
    exit 1
fi
log "=== КОНЕЦ ==="
EOF_SCRIPT

# -----------------------------------------------------------------------------
# 2. Права на выполнение основного скрипта
# -----------------------------------------------------------------------------
chmod +x /etc/storage/ipset_update.sh

# -----------------------------------------------------------------------------
# 2. Создание watchdog (с поддержкой IPv6)
# -----------------------------------------------------------------------------
cat > /etc/storage/route_watchdog.sh << 'EOF_WATCHDOG'
#!/bin/sh
modprobe ip_set_hash_net 2>/dev/null
modprobe xt_set 2>/dev/null
modprobe ip6_set 2>/dev/null
modprobe ip6_set_hash_net 2>/dev/null

INTERVAL=15
ANALYZE_INTERVAL=60
LAST_ANALYZE=0
LEARNED_CACHE="/etc/storage/learned_ips.cache"

while true; do
    if ip rule show | grep -q "not.*fwmark 0xca6c"; then
        ip rule del pref 5182 2>/dev/null
        ip rule add fwmark 0xca6c lookup 51 pref 5182
        echo "[$(date)] Watchdog: удалено not-правило" >> /tmp/route_watchdog.log
    fi

    if ! ip route show table 51 | grep -q "default dev wg0"; then
        ip route replace default dev wg0 table 51
        echo "[$(date)] Watchdog: исправлен маршрут в table 51" >> /tmp/route_watchdog.log
    fi

    if [ "$(sysctl -n net.ipv4.conf.wg0.rp_filter 2>/dev/null)" != "0" ]; then
        echo 0 > /proc/sys/net/ipv4/conf/wg0/rp_filter
        echo "[$(date)] Watchdog: исправлен rp_filter" >> /tmp/route_watchdog.log
    fi

    if ! iptables -t mangle -C PREROUTING -m set --match-set bypass_nets dst -j MARK --set-mark 0xca6c 2>/dev/null; then
        iptables -t mangle -A PREROUTING -m set --match-set bypass_nets dst -j MARK --set-mark 0xca6c
        echo "[$(date)] Watchdog: добавлено правило MARK" >> /tmp/route_watchdog.log
    fi

    if ! iptables -t mangle -C PREROUTING -m set --match-set bypass_nets dst -j CONNMARK --set-mark 0xca6c 2>/dev/null; then
        iptables -t mangle -A PREROUTING -m set --match-set bypass_nets dst -j CONNMARK --set-mark 0xca6c
        echo "[$(date)] Watchdog: добавлено правило CONNMARK save" >> /tmp/route_watchdog.log
    fi

    if ! iptables -t mangle -C PREROUTING -m connmark --mark 0xca6c -j CONNMARK --restore-mark 2>/dev/null; then
        iptables -t mangle -A PREROUTING -m connmark --mark 0xca6c -j CONNMARK --restore-mark
        echo "[$(date)] Watchdog: добавлено правило CONNMARK restore" >> /tmp/route_watchdog.log
    fi

    # Создание ipset6, если его ещё нет
    if ! ipset list bypass_nets6 >/dev/null 2>&1; then
        modprobe ip6_set_hash_net 2>/dev/null
        ipset create bypass_nets6 hash:net family inet6 maxelem 50000 2>/dev/null
        echo "[$(date)] Watchdog: создан ipset6 bypass_nets6" >> /tmp/route_watchdog.log
    fi

    # Проверка ip6tables MARK для IPv6
    if ! ip6tables -t mangle -C PREROUTING -m set --match-set bypass_nets6 dst -j MARK --set-mark 0xca6c 2>/dev/null; then
        ip6tables -t mangle -A PREROUTING -m set --match-set bypass_nets6 dst -j MARK --set-mark 0xca6c
        echo "[$(date)] Watchdog: добавлено правило ip6tables MARK" >> /tmp/route_watchdog.log
    fi

    # Проверка ip6tables CONNMARK для IPv6
    if ! ip6tables -t mangle -C PREROUTING -m set --match-set bypass_nets6 dst -j CONNMARK --set-mark 0xca6c 2>/dev/null; then
        ip6tables -t mangle -A PREROUTING -m set --match-set bypass_nets6 dst -j CONNMARK --set-mark 0xca6c
        echo "[$(date)] Watchdog: добавлено правило ip6tables CONNMARK" >> /tmp/route_watchdog.log
    fi

    ENTRIES=$(ipset list bypass_nets 2>/dev/null | grep -oE 'Number of entries: [0-9]+' | awk '{print $4}')
    if [ -n "$ENTRIES" ] && [ "$ENTRIES" -lt 100 ]; then
        if [ ! -f /tmp/ipset_update.lock ]; then
            echo "[$(date)] Watchdog: ipset почти пуст, запускаю обновление" >> /tmp/route_watchdog.log
            sh /etc/storage/ipset_update.sh &
        fi
    fi

    NOW=$(date +%s)
    if [ $(( NOW - LAST_ANALYZE )) -ge $ANALYZE_INTERVAL ]; then
        LAST_ANALYZE=$NOW
        dmesg | grep -E "DPT=443.*SYN|SYN.*DPT=443" | tail -30 | while read line; do
            DST_IP=$(echo "$line" | grep -oE 'DST=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | cut -d'=' -f2)
            if [ -n "$DST_IP" ] && ! ipset test bypass_nets "$DST_IP" 2>/dev/null; then
                ipset add bypass_nets "$DST_IP" -exist
                echo "[$(date)] Watchdog: Автоматически добавлен IP $DST_IP" >> /tmp/route_watchdog.log
                echo "$DST_IP" >> "$LEARNED_CACHE"
            fi
        done
        dmesg -c > /dev/null 2>&1
    fi

    sleep $INTERVAL
done
EOF_WATCHDOG

chmod +x /etc/storage/route_watchdog.sh

# -----------------------------------------------------------------------------
# 3. Настройка автозагрузки
# -----------------------------------------------------------------------------
cat > /etc/storage/started_script.sh << 'EOF_STARTED'
#!/bin/sh

modprobe ip_set_hash_net
modprobe xt_set
modprobe ip6_set_hash_net

( sleep 60 && sh /etc/storage/ipset_update.sh ) &
( sleep 90 && /etc/storage/route_watchdog.sh & ) &
EOF_STARTED

chmod +x /etc/storage/started_script.sh

# -----------------------------------------------------------------------------
# 4. Cron (каждые 6 часов)
# -----------------------------------------------------------------------------
if [ -d /etc/storage/cron/crontabs ]; then
    CRON_FILE="/etc/storage/cron/crontabs/admin"
    grep -q "ipset_update.sh" "$CRON_FILE" 2>/dev/null && sed -i '/ipset_update.sh/d' "$CRON_FILE"
    echo "0 */6 * * * sh /etc/storage/ipset_update.sh > /tmp/ipset_update_cron.log 2>&1" >> "$CRON_FILE"
	echo "@reboot /etc/storage/route_watchdog.sh &" >> "$CRON_FILE"
    killall crond 2>/dev/null && crond
fi

# -----------------------------------------------------------------------------
# 5. Сохранение и первый запуск
# -----------------------------------------------------------------------------
mtd_storage.sh save

echo ""
echo "=============================================="
echo "Установка v3.10.9-beta завершена. Запускаю первый импорт..."
echo "=============================================="
sh /etc/storage/ipset_update.sh

# Запускаем watchdog сразу после первого импорта
/etc/storage/route_watchdog.sh &
