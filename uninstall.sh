#!/bin/sh
# =============================================================================
#  Скрипт полного удаления системы селективной маршрутизации
#  Версия 1.1 от 2026-04-22 (исправлено восстановление WAN)
# =============================================================================

echo "=== Полное удаление системы селективной маршрутизации ==="

# Останавливаем процессы
killall route_watchdog.sh 2>/dev/null
killall ipset_update.sh 2>/dev/null

# Удаляем файлы скриптов
rm -f /etc/storage/ipset_update.sh
rm -f /etc/storage/update_cidr.sh
rm -f /etc/storage/route_watchdog.sh
rm -f /etc/storage/diagnostic.sh

# Удаляем кэш-файлы и хеши
rm -f /etc/storage/ipset_domains.cache
rm -f /etc/storage/ipset_ips.cache
rm -f /etc/storage/learned_ips.cache
rm -f /etc/storage/ipset_sources.md5
rm -f /tmp/ipset_update.lock

# Очищаем логи
rm -f /tmp/ipset_update.log
rm -f /tmp/route_watchdog.log
rm -f /tmp/update_cidr.log
rm -f /tmp/diag_snapshot.txt

# Удаляем задания cron
if [ -f /etc/storage/cron/crontabs/admin ]; then
    sed -i '/ipset_update.sh/d' /etc/storage/cron/crontabs/admin
    killall crond 2>/dev/null && crond
fi

# Удаляем правила iptables (IPv4 и IPv6)
iptables -t mangle -D PREROUTING -m set --match-set bypass_domains dst -j MARK --set-mark 0xca6c 2>/dev/null
iptables -t mangle -D PREROUTING -m set --match-set bypass_domains dst -j CONNMARK --set-mark 0xca6c 2>/dev/null
iptables -t mangle -D PREROUTING -m connmark --mark 0xca6c -j CONNMARK --restore-mark 2>/dev/null
ip6tables -t mangle -D PREROUTING -m set --match-set bypass_domains6 dst -j MARK --set-mark 0xca6c 2>/dev/null

# Удаляем policy routing
ip rule del pref 5182 2>/dev/null
ip route flush table 51 2>/dev/null
ip -6 rule del pref 5182 2>/dev/null
ip -6 route flush table 51 2>/dev/null

# Уничтожаем ipset
ipset destroy bypass_domains 2>/dev/null
ipset destroy bypass_domains6 2>/dev/null

# Восстанавливаем rp_filter
echo 1 > /proc/sys/net/ipv4/conf/wg0/rp_filter 2>/dev/null

# Очищаем dnsmasq.conf
if [ -f /etc/storage/dnsmasq/dnsmasq.conf ]; then
    sed -i '/bypass_domains/d' /etc/storage/dnsmasq/dnsmasq.conf
    kill -HUP $(pidof dnsmasq) 2>/dev/null
fi

# Очищаем автозагрузку
if [ -f /etc/storage/started_script.sh ]; then
    sed -i '/ipset_update.sh/d' /etc/storage/started_script.sh
    sed -i '/route_watchdog.sh/d' /etc/storage/started_script.sh
fi

# Восстанавливаем стандартный маршрут по умолчанию через WAN
DEFAULT_GW=$(nvram get wan_gateway)
WAN_IF=$(nvram get wan_ifname)
[ -z "$WAN_IF" ] && WAN_IF="eth3"
if [ -n "$DEFAULT_GW" ]; then
    ip route del default 2>/dev/null
    ip route add default via "$DEFAULT_GW" dev "$WAN_IF" 2>/dev/null
    echo "Восстановлен маршрут по умолчанию: via $DEFAULT_GW dev $WAN_IF"
fi

# Перезапускаем WAN-интерфейс для надёжности
ifconfig "$WAN_IF" down 2>/dev/null && ifconfig "$WAN_IF" up 2>/dev/null

# Сохраняем и перезагружаем
mtd_storage.sh save
echo "=== Удаление завершено. Перезагружаю роутер... ==="
reboot
