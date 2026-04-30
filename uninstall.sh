#!/bin/sh
# =============================================================================
#  Скрипт полного удаления системы селективной маршрутизации
#  Версия 1.3 от 2026-04-24 (соответствует v3.10.9-beta, удаляет IPv6-компоненты)
# =============================================================================

echo "=== Полное удаление системы селективной маршрутизации ==="

# Останавливаем процессы
killall route_watchdog.sh 2>/dev/null
killall ipset_update.sh 2>/dev/null

# Удаляем файлы скриптов
rm -f /etc/storage/ipset_update.sh
rm -f /etc/storage/route_watchdog.sh
rm -f /etc/storage/diagnostic.sh

# Удаляем CIDR-файлы и кэши
rm -f /etc/storage/bypass_nets.cidr
rm -f /etc/storage/bypass_nets6.cidr
rm -f /etc/storage/learned_ips.cache
rm -f /etc/storage/bypass_nets.dump
rm -f /tmp/ipset_update.lock

# Очищаем логи
rm -f /tmp/ipset_update.log
rm -f /tmp/route_watchdog.log
rm -f /tmp/ipset_update_cron.log

# Удаляем задания cron
if [ -f /etc/storage/cron/crontabs/admin ]; then
    sed -i '/ipset_update.sh/d' /etc/storage/cron/crontabs/admin
    killall crond 2>/dev/null && crond
fi

# Удаляем правила iptables (IPv4)
iptables -t mangle -D PREROUTING -m set --match-set bypass_nets dst -j MARK --set-mark 0xca6c 2>/dev/null
iptables -t mangle -D PREROUTING -m set --match-set bypass_nets dst -j CONNMARK --set-mark 0xca6c 2>/dev/null
iptables -t mangle -D PREROUTING -m connmark --mark 0xca6c -j CONNMARK --restore-mark 2>/dev/null

# Удаляем правила ip6tables (IPv6)
ip6tables -t mangle -D PREROUTING -m set --match-set bypass_nets6 dst -j MARK --set-mark 0xca6c 2>/dev/null
ip6tables -t mangle -D PREROUTING -m set --match-set bypass_nets6 dst -j CONNMARK --set-mark 0xca6c 2>/dev/null

# Удаляем policy routing (IPv4 и IPv6)
ip rule del pref 5182 2>/dev/null
ip route flush table 51 2>/dev/null
ip -6 rule del pref 5182 2>/dev/null
ip -6 route flush table 51 2>/dev/null

# Уничтожаем ipset (IPv4 и IPv6)
ipset destroy bypass_nets 2>/dev/null
ipset destroy bypass_nets6 2>/dev/null

# Восстанавливаем rp_filter
echo 1 > /proc/sys/net/ipv4/conf/wg0/rp_filter 2>/dev/null

# Очищаем автозагрузку
if [ -f /etc/storage/started_script.sh ]; then
    sed -i '/ipset_update.sh/d' /etc/storage/started_script.sh
    sed -i '/route_watchdog.sh/d' /etc/storage/started_script.sh
fi

# Восстанавливаем стандартный маршрут через WAN
DEFAULT_GW=$(nvram get wan_gateway)
WAN_IF=$(nvram get wan_ifname)
[ -z "$WAN_IF" ] && WAN_IF="eth3"
if [ -n "$DEFAULT_GW" ]; then
    ip route del default 2>/dev/null
    ip route add default via "$DEFAULT_GW" dev "$WAN_IF" 2>/dev/null
    echo "Восстановлен маршрут по умолчанию: via $DEFAULT_GW dev $WAN_IF"
fi

# Сохраняем и перезагружаем
mtd_storage.sh save
echo "=== Удаление завершено. Перезагружаю роутер... ==="
reboot