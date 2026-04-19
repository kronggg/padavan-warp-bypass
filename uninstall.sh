#!/bin/sh
# =============================================================================
#  Скрипт полного удаления системы селективной маршрутизации через AmneziaWG/WARP
#  Версия 1.0 от 2026-04-19
# =============================================================================

echo "=== Полное удаление системы селективной маршрутизации ==="

# 1. Остановка и удаление сторожевого скрипта
killall route_watchdog.sh 2>/dev/null
rm -f /etc/storage/route_watchdog.sh

# 2. Удаление основного скрипта
rm -f /etc/storage/ipset_update.sh

# 3. Удаление заданий из crontab
if [ -f /etc/storage/cron/crontabs/admin ]; then
    sed -i '/ipset_update.sh/d' /etc/storage/cron/crontabs/admin
    killall crond 2>/dev/null && crond
fi

# 4. Удаление правил iptables
iptables -t mangle -D PREROUTING -m set --match-set bypass_domains dst -j MARK --set-mark 0xca6c 2>/dev/null
iptables -t mangle -D PREROUTING -m set --match-set bypass_domains dst -j CONNMARK --set-mark 0xca6c 2>/dev/null
iptables -t mangle -D PREROUTING -m connmark --mark 0xca6c -j CONNMARK --restore-mark 2>/dev/null

# 5. Удаление правил ip6tables
ip6tables -t mangle -D PREROUTING -m set --match-set bypass_domains6 dst -j MARK --set-mark 0xca6c 2>/dev/null

# 6. Удаление правил policy routing (IPv4)
ip rule del pref 5182 2>/dev/null
ip route flush table 51 2>/dev/null

# 7. Удаление правил policy routing (IPv6)
ip -6 rule del pref 5182 2>/dev/null
ip -6 route flush table 51 2>/dev/null

# 8. Уничтожение ipset
ipset destroy bypass_domains 2>/dev/null
ipset destroy bypass_domains6 2>/dev/null

# 9. Восстановление rp_filter (возвращаем значение по умолчанию)
echo 1 > /proc/sys/net/ipv4/conf/wg0/rp_filter 2>/dev/null

# 10. Удаление записей из конфигурации dnsmasq
if [ -f /etc/storage/dnsmasq/dnsmasq.conf ]; then
    sed -i '/bypass_domains/d' /etc/storage/dnsmasq/dnsmasq.conf
    kill -HUP $(pidof dnsmasq) 2>/dev/null
fi

# 11. Очистка автозагрузки
if [ -f /etc/storage/started_script.sh ]; then
    sed -i '/ipset_update.sh/d' /etc/storage/started_script.sh
    sed -i '/route_watchdog.sh/d' /etc/storage/started_script.sh
    sed -i '/rp_filter/d' /etc/storage/started_script.sh
fi

# 12. Сохранение изменений и перезагрузка
mtd_storage.sh save
echo "=== Удаление завершено. Перезагружаю роутер... ==="
reboot
