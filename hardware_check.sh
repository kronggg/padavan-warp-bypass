#!/bin/sh
# =============================================================================
#  Скрипт проверки совместимости оборудования/прошивки с ССМ (v3.10+)
#  Версия 1.5 — устранено противоречие между версией ядра и наличием AWG/WG
# =============================================================================

# Принудительно расширяем PATH
export PATH="$PATH:/usr/sbin:/usr/bin:/sbin:/bin:/opt/sbin:/opt/bin"

echo ""
echo "=============================================="
echo "  ПРОВЕРКА СОВМЕСТИМОСТИ С ССМ"
echo "=============================================="
echo ""

ERRORS=0
WARNINGS=0

# -------------------------------------------------------------------
# 1. Версия ядра + поиск утилиты AWG/WG
# -------------------------------------------------------------------
echo "--- 1. Ядро и VPN-утилита ---"
KERNEL_VER=$(uname -r)
echo "  Версия ядра: $KERNEL_VER"

# Сначала ищем AWG, потом WG
FOUND_WG=0
for path in \
    /usr/sbin/awg /usr/bin/awg /opt/bin/awg /opt/sbin/awg \
    /usr/sbin/wg /usr/bin/wg /opt/bin/wg /opt/sbin/wg; do
    if [ -x "$path" ]; then
        FOUND_WG=1
        case "$path" in
            *awg) echo "  [OK] Найден AmneziaWG: $path" ;;
            *wg)  echo "  [OK] Найден WireGuard: $path" ;;
        esac
        break
    fi
done
if [ $FOUND_WG -eq 0 ]; then
    if which awg >/dev/null 2>&1; then
        FOUND_WG=1
        echo "  [OK] Найден AmneziaWG"
    elif which wg >/dev/null 2>&1; then
        FOUND_WG=1
        echo "  [OK] Найден WireGuard"
    fi
fi

# Теперь анализируем версию ядра С УЧЁТОМ найденной утилиты
case "$KERNEL_VER" in
    4.[4-9]*|4.[1-9][0-9]*|[5-9]*|[1-9][0-9]*)
        echo "  [OK] Ядро $KERNEL_VER полностью совместимо"
        ;;
    3.4*)
        if [ $FOUND_WG -eq 1 ]; then
            echo "  [OK] Ядро 3.4.x + найден модуль AWG/WG — совместимо"
        else
            echo "  [FAIL] Ядро 3.4.x без AWG/WG модуля. VPN не сможет работать."
            ERRORS=$((ERRORS+1))
        fi
        ;;
    *)
        echo "  [FAIL] Неизвестная версия ядра. Рекомендуется ядро 4.4+"
        ERRORS=$((ERRORS+1))
        ;;
esac

# -------------------------------------------------------------------
# 2. ipset
# -------------------------------------------------------------------
echo "--- 2. ipset ---"
FOUND_IPSET=0
for path in /usr/sbin/ipset /usr/bin/ipset /opt/sbin/ipset /opt/bin/ipset; do
    if [ -x "$path" ]; then
        FOUND_IPSET=1
        break
    fi
done
if [ $FOUND_IPSET -eq 1 ] || which ipset >/dev/null 2>&1; then
    echo "  [OK] ipset найден"
else
    echo "  [FAIL] ipset не найден. Селективная маршрутизация невозможна."
    ERRORS=$((ERRORS+1))
fi

# -------------------------------------------------------------------
# 3. iptables
# -------------------------------------------------------------------
echo "--- 3. iptables ---"
FOUND_IPT=0
for path in /usr/sbin/iptables /usr/bin/iptables /opt/sbin/iptables /opt/bin/iptables; do
    if [ -x "$path" ]; then
        FOUND_IPT=1
        break
    fi
done
if [ $FOUND_IPT -eq 1 ] || which iptables >/dev/null 2>&1; then
    echo "  [OK] iptables найден"
else
    echo "  [FAIL] iptables не найден. Правила маркировки трафика не будут работать."
    ERRORS=$((ERRORS+1))
fi

# -------------------------------------------------------------------
# 4. wget или curl
# -------------------------------------------------------------------
echo "--- 4. wget/curl ---"
FOUND_DL=0
for path in /usr/bin/wget /usr/sbin/wget /opt/bin/wget /usr/bin/curl /usr/sbin/curl /opt/bin/curl; do
    if [ -x "$path" ]; then
        FOUND_DL=1
        break
    fi
done
if [ $FOUND_DL -eq 1 ] || which wget >/dev/null 2>&1 || which curl >/dev/null 2>&1; then
    echo "  [OK] Утилита для скачивания найдена"
else
    echo "  [FAIL] Ни wget, ни curl не найдены. Не сможем скачивать CIDR-списки."
    ERRORS=$((ERRORS+1))
fi

# -------------------------------------------------------------------
# 5. Свободное место в /etc/storage (порог 512 КБ)
# -------------------------------------------------------------------
echo "--- 5. Свободное место в /etc/storage ---"
if [ -d /etc/storage ]; then
    AVAIL=$(df -k /etc/storage 2>/dev/null | tail -1 | awk '{print $4}')
    TOTAL=$(df -k /etc/storage 2>/dev/null | tail -1 | awk '{print $2}')
    if [ -n "$AVAIL" ]; then
        if [ "$AVAIL" -ge 512 ]; then
            echo "  [OK] Доступно ${AVAIL} KB (из ${TOTAL} KB) — достаточно для CIDR-файлов"
        else
            echo "  [WARN] Доступно ${AVAIL} KB (из ${TOTAL} KB). Рекомендуется освободить место."
            WARNINGS=$((WARNINGS+1))
        fi
    else
        echo "  [WARN] Не удалось определить свободное место."
        WARNINGS=$((WARNINGS+1))
    fi
else
    echo "  [WARN] /etc/storage не найден (возможно не Padavan)."
    WARNINGS=$((WARNINGS+1))
fi

# -------------------------------------------------------------------
# 6. Архитектура процессора
# -------------------------------------------------------------------
echo "--- 6. Архитектура процессора ---"
ARCH=$(uname -m)
echo "  Обнаружена архитектура: $ARCH"
case "$ARCH" in
    mips|armv7l|aarch64)
        echo "  [OK] Архитектура $ARCH поддерживается"
        ;;
    *)
        echo "  [WARN] Архитектура $ARCH не тестировалась. Может работать, но возможны нюансы."
        WARNINGS=$((WARNINGS+1))
        ;;
esac

# -------------------------------------------------------------------
# 7. Доступность GitHub
# -------------------------------------------------------------------
echo "--- 7. Доступность GitHub ---"
if ping -c 1 -W 1 raw.githubusercontent.com >/dev/null 2>&1; then
    echo "  [OK] GitHub доступен"
else
    echo "  [WARN] GitHub недоступен. Установка одной командой не сработает."
    WARNINGS=$((WARNINGS+1))
fi

# -------------------------------------------------------------------
# Итоги
# -------------------------------------------------------------------
echo ""
echo "=============================================="
echo "                 ИТОГИ ПРОВЕРКИ"
echo "=============================================="
echo ""
echo "  Ошибок:    $ERRORS"
echo "  Предупреждений: $WARNINGS"
echo ""

if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo "  Система полностью совместима. Можно устанавливать ССМ."
elif [ $ERRORS -eq 0 ]; then
    echo "  Система совместима, но есть незначительные ограничения."
    echo "  Установка возможна, но рекомендуется устранить предупреждения."
else
    echo "  Обнаружены критические несовместимости."
    echo "  Установка не рекомендуется до устранения ошибок."
fi

echo ""
echo "=============================================="
echo "Проверка завершена."