#!/bin/bash
# ==# ========================================================================
# Скрипт: system-check.sh
# Описание: Проверка системы перед установкой Asterisk/FreePBX
# Версия: 2.0
# Дата: 2026-04-23
# Автор: Master Automation==============================================================
# Скрипт: system-check.sh
# Описание: Проверка системы перед установкой Asterisk/FreePBX
# Версия: 2.0
# Дата: 2026-04-23
# Автор: Master Automation
# ========================================================================
#
# Содержание:
#   1.  check_os               - Проверка версии ОС (Debian 12)
#   2.  check_ram              - Проверка оперативной памяти (минимум 2 ГБ)
#   3.  check_swap             - Проверка наличия и активности swap
#   4.  check_selinux          - Проверка, отключён ли SELinux
#   5.  check_apache_mod_rewrite - Проверка доступности модуля Apache mod_rewrite
#   6.  check_filesystem       - Проверка типа файловой системы (рекомендуется ext4/xfs)
#   7.  check_kernel_version   - Проверка версии ядра (нужно >= 2.6.25)
#   8.  check_internet         - Проверка доступа в интернет
#   9.  check_ports            - Проверка занятости портов (5060, 80, 443, 3306)
#   10. check_pkg_conflicts    - Проверка конфликтующих пакетов
#  11. check_disk_space       - Проверка свободного места на диске (>= 5 ГБ)
#  12. check_write_permissions - Проверка прав на запись в каталоги
#  13. check_hostname         - Проверка корректности hostname
#  14. check_time_sync        - Проверка синхронизации времени (NTP)
#  15. check_static_ip        - Проверка статического IP-адреса
#  16. check_locale           - Проверка системной локали
#  17. check_system_updates    - Проверка наличия обновлений системы
#  18. check_all              - Групповая проверка (запуск всех вышеперечисленных)
# ========================================================================
#
# Коды ошибок
readonly E_CRIT=2
readonly E_WARN=1
readonly E_OK=0

# Цвета
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# ------------------------------------------------------------------
print_header() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

print_ok() {
    echo -e "${GREEN}[OK]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# ------------------------------------------------------------------
# Проверка обновлений
check_system_updates() {
    print_header "System Updates"
    local updates
    # apt-get --just-print upgrade быстрее и не требует полного списка
    updates=$(apt-get --just-print upgrade 2>/dev/null | grep -c '^Inst' || echo 0)
    if [ "$updates" -gt 0 ]; then
        print_warning "$updates updates available. Run 'apt upgrade' to install them."
        return $E_WARN
    else
        print_ok "System is up to date."
        return $E_OK
    fi
}

# ------------------------------------------------------------------
# Проверка дискового пространства
check_disk_space() {
    print_header "Disk Space"
    local threshold=80
    local ret=0
    local usage partition
    # Исправление: использование process substitution, чтобы избежать subshell
    # и инициализация переменных внутри основного процесса.
    while read -r usage partition; do
        if [ "$usage" -gt "$threshold" ]; then
            print_error "$partition is $usage% full."
            ret=1
        fi
    done < <(
        df -h -x tmpfs -x devtmpfs -x udev --output=pcent,target 2>/dev/null |
        tail -n +2 |
        awk '{gsub(/%/,"",$1); print $1, $2}'
    )
    if [ "$ret" -eq 0 ]; then
        print_ok "Disk space OK."
    fi
    return "$ret"
}

# ------------------------------------------------------------------
# Проверка использования памяти
check_memory_usage() {
    print_header "Memory Usage"
    local meminfo
    meminfo=$(free -m | awk '/^Mem:/{printf "%.0f", $3/$2*100}')
    if [ "$meminfo" -gt 90 ]; then
        print_error "Memory usage is high (${meminfo}%)"
        return $E_WARN
    else
        print_ok "Memory usage is ${meminfo}%."
        return $E_OK
    fi
}

# ------------------------------------------------------------------
# Проверка средней нагрузки
check_load_average() {
    print_header "Load Average"
    local load
    load=$(uptime | awk -F'load average: ' '{print $2}' | awk '{print $1}' | tr -d ',')
    local cores
    cores=$(nproc)
    if awk -v l="$load" -v c="$cores" 'BEGIN{exit !(l > c)}'; then
        print_warning "Load average ($load) exceeds number of cores ($cores)."
        return $E_WARN
    else
        print_ok "Load average is $load."
        return $E_OK
    fi
}

# ------------------------------------------------------------------
# Проверка состояния сервисов
check_services() {
    print_header "Services"
    local services=("apache2" "mysql" "freepbx" "asterisk")
    local ret=0
    for srv in "${services[@]}"; do
        if systemctl is-active --quiet "$srv"; then
            print_ok "$srv is active."
        else
            print_error "$srv is not running."
            ret=1
        fi
    done
    return "$ret"
}

# ------------------------------------------------------------------
# Проверка сетевой связности
check_network() {
    print_header "Network Connectivity"
    if ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1; then
        print_ok "Network connectivity OK."
        return $E_OK
    else
        print_error "Network connectivity failed."
        return $E_CRIT
    fi
}

# ------------------------------------------------------------------
# Проверка открытых портов (TCP listen)
check_open_ports() {
    print_header "Open Ports"
    local ports
    # Используем ss -tln с фильтрацией LISTEN для надёжности
    ports=$(ss -tln 2>/dev/null | grep LISTEN | awk '{print $4}' | awk -F: '{print $NF}' | sort -un | tr '\n' ' ')
    if [ -z "$ports" ]; then
        print_ok "No listening TCP ports detected."
    else
        print_info "Listening TCP ports: $ports"
    fi
    return $E_OK
}

# ------------------------------------------------------------------
# Проверка состояния файрвола
check_firewall_status() {
    print_header "Firewall Status"
    # Проверка наличия команды iptables
    if ! command -v iptables >/dev/null 2>&1; then
        print_warning "iptables command not found."
        return $E_WARN
    fi
    local rules
    rules=$(iptables -L 2>/dev/null | grep -vE "^Chain|^target|^$" || true)
    if [ -z "$rules" ]; then
        print_ok "No iptables rules configured."
    else
        print_info "iptables rules are configured."
    fi
    return $E_OK
}

# ------------------------------------------------------------------
# Проверка пакетов безопасности
check_security_packages() {
    print_header "Security Packages"
    local ret=0
    local pkg
    # Используем dpkg-query для точечного запроса статуса
    for pkg in fail2ban unattended-upgrades; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
            print_ok "$pkg is installed."
        else
            print_warning "$pkg is not installed."
            ret=1
        fi
    done
    return "$ret"
}

# ------------------------------------------------------------------
# Главная функция
check_all() {
    local final_ret=0
    check_system_updates   || final_ret=$?
    check_disk_space       || final_ret=$?
    check_memory_usage     || final_ret=$?
    check_load_average     || final_ret=$?
    check_services         || final_ret=$?
    check_network          || final_ret=$?
    check_open_ports       || final_ret=$?
    check_firewall_status  || final_ret=$?
    check_security_packages || final_ret=$?
    echo
    if [ "$final_ret" -eq 0 ]; then
        print_ok "All checks passed."
    else
        print_warning "Some checks reported issues. Review output above."
    fi
    return "$final_ret"
}

# Если скрипт запущен напрямую
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    check_all
fi


# Использование:
#   ./system-check.sh            - вывод справки
#   ./system-check.sh check_all  - запустить все проверки
#   ./system-check.sh check_ram  - запустить только проверку RAM
# ========================================================================