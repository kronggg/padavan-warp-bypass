#!/bin/sh
# =============================================================================
#  Диагностика системы селективной маршрутизации v3.10+
#  Версия для GitHub (исправлена синтаксическая ошибка)
# =============================================================================

echo ""
echo "=============================================="
echo "  ДИАГНОСТИКА СИСТЕМЫ СЕЛЕКТИВНОЙ МАРШРУТИЗАЦИИ v3.10+"
echo "=============================================="
echo ""

ERRORS=0
WARNINGS=0
RECOMMENDATIONS=""

# -----------------------------------------------------------------------------
# 1. Модули ядра
# -----------------------------------------------------------------------------
echo "--- 1. Модули ядра ---"
if lsmod | grep -q ip_set_hash_net; then
    echo "  [OK] ip_set_hash_net загружен"
else
    echo "  [FAIL] ip_set_hash_net НЕ загружен"
    ERRORS=$((ERRORS+1))
fi

if lsmod | grep -q ip6_set_hash_net; then
    echo "  [OK] ip6_set_hash_net загружен"
else
    echo "  [WARN] ip6_set_hash_net НЕ загружен (IPv6 не будет работать)"
    RECOMMENDATIONS="${RECOMMENDATIONS}
  - IPv6: Убедитесь, что провайдер поддерживает IPv6. В веб-интерфейсе роутера (WAN → Протокол IPv6) установите 'Тип подключения' = 'Native DHCPv6'. В разделе 'Настройки IPv6 для LAN' включите 'Получать IPv6-адрес LAN через DHCPv6 IA-PD'. Если провайдер не поддерживает IPv6, предупреждение можно игнорировать."
    WARNINGS=$((WARNINGS+1))
fi
if lsmod | grep -q xt_set; then
    echo "  [OK] xt_set загружен"
else
    echo "  [WARN] xt_set НЕ загружен"
    WARNINGS=$((WARNINGS+1))
fi

# -----------------------------------------------------------------------------
# 2. VPN-туннель
# -----------------------------------------------------------------------------
echo "--- 2. Состояние VPN-туннеля (wg0) ---"
if ip link show wg0 >/dev/null 2>&1; then
    echo "  [OK] Интерфейс wg0 существует"
    STATE=$(ip link show wg0 | grep -oE 'state [A-Z]+' | awk '{print $2}')
    echo "  [OK] Состояние: $STATE"
    IP=$(ip -4 addr show wg0 | grep -oE 'inet [0-9.]+' | awk '{print $2}')
    [ -n "$IP" ] && echo "  [OK] IPv4 адрес: $IP" || { echo "  [FAIL] IPv4 адрес отсутствует"; ERRORS=$((ERRORS+1)); }
    if curl --interface wg0 --max-time 5 -s -o /dev/null -w "%{http_code}" http://cp.cloudflare.com | grep -qE "200|204|301|302"; then
        echo "  [OK] Трафик через туннель проходит"
    else
        echo "  [WARN] Трафик через туннель не проходит"
        WARNINGS=$((WARNINGS+1))
    fi
else
    echo "  [FAIL] Интерфейс wg0 НЕ НАЙДЕН"
    ERRORS=$((ERRORS+1))
fi

# -----------------------------------------------------------------------------
# 3. ipset (IPv4 и IPv6)
# -----------------------------------------------------------------------------
echo "--- 3. Состояние ipset ---"
if ipset list bypass_nets >/dev/null 2>&1; then
    ENTRIES=$(ipset list bypass_nets | grep -oE 'Number of entries: [0-9]+' | awk '{print $4}')
    echo "  [OK] ipset bypass_nets существует (записей: $ENTRIES)"
    if [ "$ENTRIES" -lt 1000 ]; then
        echo "  [WARN] Подозрительно мало записей, возможно, требуется обновление"
        WARNINGS=$((WARNINGS+1))
    fi
else
    echo "  [FAIL] ipset bypass_nets НЕ СУЩЕСТВУЕТ"
    ERRORS=$((ERRORS+1))
fi

if ipset list bypass_nets6 >/dev/null 2>&1; then
    ENTRIES6=$(ipset list bypass_nets6 | grep -oE 'Number of entries: [0-9]+' | awk '{print $4}')
    echo "  [OK] ipset bypass_nets6 существует (записей: $ENTRIES6)"
    if [ "$ENTRIES6" -lt 10 ]; then
        echo "  [WARN] Слишком мало IPv6 подсетей, возможно, не обновлялся"
        WARNINGS=$((WARNINGS+1))
    fi
else
    echo "  [FAIL] ipset bypass_nets6 НЕ СУЩЕСТВУЕТ"
    ERRORS=$((ERRORS+1))
fi

# -----------------------------------------------------------------------------
# 4. Правила iptables (IPv4 и IPv6)
# -----------------------------------------------------------------------------
echo "--- 4. Правила iptables (mangle PREROUTING) ---"
if iptables -t mangle -C PREROUTING -m set --match-set bypass_nets dst -j MARK --set-mark 0xca6c 2>/dev/null; then
    echo "  [OK] Правило MARK (IPv4) присутствует"
else
    echo "  [FAIL] Правило MARK (IPv4) ОТСУТСТВУЕТ"
    ERRORS=$((ERRORS+1))
fi
if iptables -t mangle -C PREROUTING -m set --match-set bypass_nets dst -j CONNMARK --set-mark 0xca6c 2>/dev/null; then
    echo "  [OK] Правило CONNMARK save (IPv4) присутствует"
else
    echo "  [WARN] Правило CONNMARK save (IPv4) отсутствует"
    WARNINGS=$((WARNINGS+1))
fi
if iptables -t mangle -C PREROUTING -m connmark --mark 0xca6c -j CONNMARK --restore-mark 2>/dev/null; then
    echo "  [OK] Правило CONNMARK restore (IPv4) присутствует"
else
    echo "  [WARN] Правило CONNMARK restore (IPv4) отсутствует"
    WARNINGS=$((WARNINGS+1))
fi

if ip6tables -t mangle -C PREROUTING -m set --match-set bypass_nets6 dst -j MARK --set-mark 0xca6c 2>/dev/null; then
    echo "  [OK] Правило MARK (IPv6) присутствует"
else
    echo "  [WARN] Правило MARK (IPv6) отсутствует"
    WARNINGS=$((WARNINGS+1))
fi
if ip6tables -t mangle -C PREROUTING -m set --match-set bypass_nets6 dst -j CONNMARK --set-mark 0xca6c 2>/dev/null; then
    echo "  [OK] Правило CONNMARK save (IPv6) присутствует"
else
    echo "  [WARN] Правило CONNMARK save (IPv6) отсутствует"
    WARNINGS=$((WARNINGS+1))
fi

# -----------------------------------------------------------------------------
# 5. Policy routing (IPv4 и IPv6)
# -----------------------------------------------------------------------------
echo "--- 5. Policy routing ---"
RULE=$(ip rule show | grep 5182)
if echo "$RULE" | grep -q "fwmark 0xca6c lookup 51" && ! echo "$RULE" | grep -q "not"; then
    echo "  [OK] Правило ip rule (IPv4) корректно"
else
    echo "  [FAIL] Правило ip rule (IPv4) НЕКОРРЕКТНО: $RULE"
    ERRORS=$((ERRORS+1))
fi
if ip route show table 51 | grep -q "default dev wg0"; then
    echo "  [OK] Маршрут в таблице 51 (IPv4): default dev wg0"
else
    echo "  [FAIL] Маршрут в таблице 51 (IPv4) ОТСУТСТВУЕТ"
    ERRORS=$((ERRORS+1))
fi

if ip -6 rule show | grep -q "5182.*fwmark 0xca6c lookup 51"; then
    echo "  [OK] Правило ip -6 rule (IPv6) присутствует"
else
    echo "  [WARN] Правило ip -6 rule (IPv6) отсутствует"
    WARNINGS=$((WARNINGS+1))
fi
if ip -6 route show table 51 | grep -q "default dev wg0"; then
    echo "  [OK] Маршрут в таблице 51 (IPv6): default dev wg0"
else
    echo "  [WARN] Маршрут в таблице 51 (IPv6) отсутствует"
    WARNINGS=$((WARNINGS+1))
fi

if [ "$(sysctl -n net.ipv4.conf.wg0.rp_filter 2>/dev/null)" = "0" ]; then
    echo "  [OK] rp_filter для wg0 = 0"
else
    echo "  [WARN] rp_filter для wg0 != 0"
    WARNINGS=$((WARNINGS+1))
fi

# -----------------------------------------------------------------------------
# 6. Watchdog
# -----------------------------------------------------------------------------
echo "--- 6. Watchdog ---"
if ps | grep -q '[r]oute_watchdog'; then
    echo "  [OK] Процесс watchdog запущен"
else
    echo "  [FAIL] Процесс watchdog НЕ ЗАПУЩЕН"
    ERRORS=$((ERRORS+1))
fi

# -----------------------------------------------------------------------------
# 7. Лог основного скрипта
# -----------------------------------------------------------------------------
echo "--- 7. Лог основного скрипта (ipset_update.sh) ---"
if [ -f /tmp/ipset_update.log ]; then
    LAST_END=$(grep "=== КОНЕЦ ===" /tmp/ipset_update.log | tail -1)
    if [ -n "$LAST_END" ]; then
        echo "  [OK] Последний запуск успешен"
    else
        echo "  [WARN] Нет подтверждения успешного завершения"
        WARNINGS=$((WARNINGS+1))
    fi
else
    echo "  [WARN] Лог отсутствует"
    WARNINGS=$((WARNINGS+1))
fi

# -----------------------------------------------------------------------------
# 8. Автозагрузка
# -----------------------------------------------------------------------------
echo "--- 8. Автозагрузка ---"
if grep -q "ipset_update.sh" /etc/storage/started_script.sh; then
    echo "  [OK] ipset_update.sh прописан в started_script.sh"
else
    echo "  [FAIL] ipset_update.sh НЕ ПРОПИСАН"
    ERRORS=$((ERRORS+1))
fi
if grep -q "ip_set_hash_net" /etc/storage/started_script.sh; then
    echo "  [OK] Модуль ip_set_hash_net загружается при старте"
else
    echo "  [WARN] Модуль ip_set_hash_net НЕ загружается при старте"
    WARNINGS=$((WARNINGS+1))
fi

# -----------------------------------------------------------------------------
# Итоги
# -----------------------------------------------------------------------------
echo ""
echo "=============================================="
echo "                 ИТОГИ ДИАГНОСТИКИ"
echo "=============================================="
echo ""
echo "  Ошибок:    $ERRORS"
echo "  Предупреждений: $WARNINGS"
echo ""

if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo "  Система полностью исправна!"
elif [ $ERRORS -eq 0 ]; then
    echo "  Система работает, но есть незначительные предупреждения."
else
    echo "  Обнаружены критические ошибки!"
fi

if [ -n "$RECOMMENDATIONS" ]; then
    echo ""
    echo "  Рекомендации:"
    echo "$RECOMMENDATIONS"
fi

echo ""
echo "=============================================="
echo "Диагностика завершена."
