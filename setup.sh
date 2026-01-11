#!/bin/bash

# Lightweight VPS Setup for Remnawave
# Author: Kilo Code
# Version: 1.4.0
#
# Этот скрипт выполняет базовую настройку и укрепление безопасности
# для свежеустановленного сервера Debian/Ubuntu.

# --- Цвета и стили для вывода ---
COLOR_RESET='\033[0m'
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_BLUE='\033[0;34m'
COLOR_CYAN='\033[0;36m'
STYLE_BOLD='\033[1m'

# --- Переменные окружения ---
SSH_PORT="${SSH_PORT:-1337}"
INSTALL_TBLOCKER="${INSTALL_TBLOCKER:-false}"
BLOCK_ICMP="${BLOCK_ICMP:-false}"
DISABLE_IPV6="${DISABLE_IPV6:-false}"
TIMEZONE="${TIMEZONE:-}"

# Важное предупреждение о порте 2222 для Remnawave
# Порт 2222 используется панелью Remnawave и должен оставаться открытым!
REMNWAVE_PANEL_PORT=2222

# Новые переменные для расширенных функций
ENABLE_BBR="${ENABLE_BBR:-true}"
ENABLE_KERNEL_HARDENING="${ENABLE_KERNEL_HARDENING:-true}"
ENABLE_NETWORK_LIMITS="${ENABLE_NETWORK_LIMITS:-true}"
ENABLE_LOGROTATE="${ENABLE_LOGROTATE:-true}"
ENABLE_CLEANUP="${ENABLE_CLEANUP:-true}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-90}"
DRY_RUN="${DRY_RUN:-false}"

# Пути к файлам
BACKUP_DIR="/root/.vps-setup-backups"
LOG_FILE="/var/log/vps-setup.log"
REPORT_FILE="/root/vps-setup-report-$(date +%Y%m%d_%H%M%S).txt"

# --- Функции для вывода сообщений ---
log_info() {
    echo -e "${COLOR_BLUE}ℹ${COLOR_RESET}  $*" | tee -a "$LOG_FILE" 2>/dev/null || echo -e "${COLOR_BLUE}ℹ${COLOR_RESET}  $*"
}

log_success() {
    echo -e "${COLOR_GREEN}✅${COLOR_RESET} $*" | tee -a "$LOG_FILE" 2>/dev/null || echo -e "${COLOR_GREEN}✅${COLOR_RESET} $*"
}

log_warn() {
    echo -e "${COLOR_YELLOW}⚠️${COLOR_RESET}  $*" | tee -a "$LOG_FILE" 2>/dev/null || echo -e "${COLOR_YELLOW}⚠️${COLOR_RESET} $*"
}

log_error() {
    echo -e "${COLOR_RED}❌${COLOR_RESET} $*" | tee -a "$LOG_FILE" 2>/dev/null >&2 || echo -e "${COLOR_RED}❌${COLOR_RESET} $*" >&2
}

log_step() {
    echo -e "\n${STYLE_BOLD}${COLOR_CYAN}═══ $* ═══${COLOR_RESET}" | tee -a "$LOG_FILE" 2>/dev/null || echo -e "\n${STYLE_BOLD}${COLOR_CYAN}═══ $* ═══${COLOR_RESET}"
}

# --- Проверки перед запуском ---

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "Этот скрипт должен быть запущен от имени root или с использованием sudo."
        exit 1
    fi
}

check_os() {
    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        OS=$NAME
        VER=$VERSION_ID
        if [[ "$OS" == "Ubuntu" && ("$VER" == "20.04" || "$VER" == "22.04" || "$VER" == "24.04") ]] || \
           [[ "$OS" == "Debian GNU/Linux" && ("$VER" == "11" || "$VER" == "12") ]]; then
            log_success "Обнаружена поддерживаемая ОС: $OS $VER."
        else
            log_error "Ваша ОС ($OS $VER) не поддерживается. Скрипт предназначен для Debian 11/12 и Ubuntu 20.04/22.04/24.04."
            exit 1
        fi
    else
        log_error "Не удалось определить вашу операционную систему."
        exit 1
    fi
}

# --- Вспомогательные функции ---

generate_random_port() {
    echo $((RANDOM % 40000 + 10000))
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1024 ]] && [[ "$port" -le 65535 ]]
}

# --- Функции безопасности для SSH ---

# Проверка конфигурации SSH на наличие ошибок
validate_ssh_config() {
    local config_file="/etc/ssh/sshd_config"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "[DRY-RUN] Would validate SSH config"
        return 0
    fi
    
    # Проверка существования файла конфигурации
    if [[ ! -f "$config_file" ]]; then
        log_error "❌ КРИТИЧЕСКАЯ ОШИБКА: Файл конфигурации SSH не найден: $config_file"
        log_error "Отмена изменений..."
        return 1
    fi
    
    # Проверка прав доступа к файлу конфигурации
    log_info "Проверка прав доступа к файлу конфигурации SSH: $config_file"
    local file_perms=$(stat -c "%a" "$config_file" 2>/dev/null || echo "unknown")
    log_info "Права доступа к файлу: $file_perms"
    
    if [[ ! -r "$config_file" ]]; then
        log_error "❌ КРИТИЧЕСКАЯ ОШИБКА: Нет прав на чтение файла конфигурации SSH: $config_file"
        log_error "Отмена изменений..."
        return 1
    fi
    
    # Проверка доступности команды sshd
    if ! command -v sshd &>/dev/null; then
        log_error "❌ КРИТИЧЕСКАЯ ОШИБКА: Команда sshd не найдена!"
        log_error "Отмена изменений..."
        return 1
    fi
    
    # Диагностическое логирование перед валидацией
    log_info "Начало валидации конфигурации SSH: $config_file"
    
    # Проверка конфигурации SSH на синтаксические ошибки с try-catch для перехвата исключений
    local sshd_output=""
    local sshd_exit_code=0
    
    # Выполняем валидацию и перехватываем вывод и код возврата с обработкой ошибок
    log_info "Выполнение команды: sshd -t"
    
    # Используем set +e для временного отключения выхода при ошибке
    local old_set_opts="$-"
    set +e
    
    # Выполняем команду и перехватываем вывод (sshd -t автоматически использует /etc/ssh/sshd_config)
    sshd_output=$(sshd -t 2>&1)
    sshd_exit_code=$?
    
    # Восстанавливаем предыдущие настройки
    case "$old_set_opts" in
        *e*) set -e ;;
    esac
    
    # Логируем код возврата
    log_info "Код возврата sshd -t: $sshd_exit_code"
    
    # Логируем вывод (если есть ошибки)
    if [[ -n "$sshd_output" ]]; then
        log_error "❌ Вывод sshd -t: $sshd_output"
    else
        log_info "Вывод sshd -t: (пусто)"
    fi
    
    # Проверяем код возврата
    if [[ $sshd_exit_code -ne 0 ]]; then
        log_error "❌ КРИТИЧЕСКАЯ ОШИБКА: Конфигурация SSH содержит ошибки!"
        log_error "Пожалуйста, проверьте конфигурацию вручную:"
        log_error "  sshd -t"
        log_error "Отмена изменений..."
        return 1
    fi
    
    log_success "✅ Конфигурация SSH валидна"
    return 0
}

# Проверка доступности порта SSH
check_ssh_port_accessible() {
    local port="$1"
    local timeout="${2:-5}"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "[DRY-RUN] Would check SSH port accessibility"
        return 0
    fi
    
    # Проверка, слушается ли порт SSH
    if command -v ss &>/dev/null; then
        if ! ss -tuln | grep -q ":$port "; then
            log_warn "⚠️ Порт $port не используется SSH на данный момент"
            return 1
        fi
    else
        if ! netstat -tuln 2>/dev/null | grep -q ":$port "; then
            log_warn "⚠️ Порт $port не используется SSH на данный момент"
            return 1
        fi
    fi
    
    log_success "✅ Порт $port доступен для SSH"
    return 0
}

# Сохранение текущей конфигурации SSH для возможного отката
save_current_ssh_config() {
    local backup_dir="/root/.ssh-backups"
    local config_file="/etc/ssh/sshd_config"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "[DRY-RUN] Would backup SSH config"
        return 0
    fi
    
    mkdir -p "$backup_dir"
    local backup_file="$backup_dir/sshd_config.before-$(date +%Y%m%d_%H%M%S).bak"
    
    if [[ -f "$config_file" ]]; then
        cp "$config_file" "$backup_file"
        log_success "✅ Текущая конфигурация SSH сохранена: $backup_file"
    else
        log_warn "⚠️ Файл конфигурации SSH не найден: $config_file"
    fi
}

# Проверка состояния службы SSH
check_ssh_status() {
    local timeout="${1:-10}"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "[DRY-RUN] Would check SSH status"
        return 0
    fi
    
    # Проверка, работает ли служба SSH
    if ! systemctl is-active ssh >/dev/null 2>&1 && \
       ! systemctl is-active sshd >/dev/null 2>&1; then
        log_warn "⚠️ Служба SSH не активна"
        return 1
    fi
    
    log_success "✅ Служба SSH активна"
    return 0
}

# Проверка конфликтов портов
check_port_conflicts() {
    local port="$1"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "[DRY-RUN] Would check port conflicts"
        return 0
    fi
    
    # Проверка, используется ли порт другим процессом
    if command -v ss &>/dev/null; then
        local process_info=$(ss -tulnp | grep ":$port " | head -1)
        if [[ -n "$process_info" ]]; then
            local pid=$(echo "$process_info" | awk '{print $7}' | cut -d, -f1)
            local process_name=$(echo "$process_info" | awk '{print $6}')
            log_warn "⚠️ Порт $port уже используется процессом: $process_name (PID: $pid)"
            return 1
        fi
    else
        local process_info=$(netstat -tulnp 2>/dev/null | grep ":$port " | head -1)
        if [[ -n "$process_info" ]]; then
            local pid=$(echo "$process_info" | awk '{print $7}')
            local process_name=$(echo "$process_info" | awk '{print $6}')
            log_warn "⚠️ Порт $port уже используется процессом: $process_name (PID: $pid)"
            return 1
        fi
    fi
    
    log_success "✅ Порт $port свободен"
    return 0
}

backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        mkdir -p "$BACKUP_DIR"
        cp "$file" "${BACKUP_DIR}/$(basename "$file").$(date +%Y%m%d_%H%M%S).bak"
    fi
}

write_config() {
    local path="$1"
    local content="$2"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "[DRY-RUN] Would create: $path"
        return 0
    fi
    backup_file "$path"
    mkdir -p "$(dirname "$path")"
    echo "$content" > "$path"
}

systemd_setup() {
    local service="$1"
    local action="${2:-restart}"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "[DRY-RUN] systemctl $action $service"
        return 0
    fi
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable "$service" >/dev/null 2>&1
    systemctl "$action" "$service" >/dev/null 2>&1
}

# --- Основные функции настройки ---

update_system() {
    log_info "Обновление списка пакетов и системы..."
    if [[ "$DRY_RUN" != "true" ]]; then
        apt-get update >/dev/null 2>&1
        apt-get upgrade -y >/dev/null 2>&1
    fi
    log_success "Система успешно обновлена."
}

setup_ssh() {
    local port=${1:-1337}
    log_info "Настройка безопасного SSH на порту $port..."
    
    # Предупреждение о важности порта 2222 для Remnawave
    if [[ "$port" != "2222" ]]; then
        log_warn "${STYLE_BOLD}⚠️  ВНИМАНИЕ: Порт 2222 используется панелью Remnawave!${COLOR_RESET}"
        log_warn "Если вы планируете использовать Remnawave, оставьте порт 2222 открытым."
        log_warn "Порт 2222 должен быть доступен для корректной работы панели."
        echo ""
    fi
    
    # Шаг 1: Проверка текущего состояния SSH перед изменениями
    log_step "Проверка текущего состояния SSH"
    if ! check_ssh_status; then
        log_error "❌ Служба SSH не активна. Невозможно продолжить."
        log_error "Пожалуйста, запустите SSH вручную: systemctl start ssh"
        exit 1
    fi
    
    # Шаг 2: Сохранение текущей конфигурации SSH для возможного отката
    log_step "Сохранение текущей конфигурации SSH"
    save_current_ssh_config
    
    # Шаг 3: Проверка конфликтов портов
    log_step "Проверка конфликтов портов"
    if ! check_port_conflicts "$port"; then
        log_error "❌ Порт $port уже используется другим процессом."
        log_error "Пожалуйста, выберите другой порт или остановите конфликтующий процесс."
        exit 1
    fi
    
    # Шаг 4: Изменение конфигурации SSH
    log_step "Изменение конфигурации SSH"
    if [[ "$DRY_RUN" != "true" ]]; then
        log_info "Текущий порт в конфигурации SSH (до изменения):"
        grep -E "^#?Port" /etc/ssh/sshd_config || echo "Строка Port не найдена"
        
        log_info "Изменение порта SSH на $port..."
        sed -i "s/^#?Port .*/Port $port/" /etc/ssh/sshd_config
        
        log_info "Изменение PermitRootLogin на yes..."
        sed -i "s/^#?PermitRootLogin .*/PermitRootLogin yes/" /etc/ssh/sshd_config
        
        log_info "Изменение PasswordAuthentication на yes..."
        sed -i "s/^#?PasswordAuthentication .*/PasswordAuthentication yes/" /etc/ssh/sshd_config
        
        log_info "Изменение ChallengeResponseAuthentication на no..."
        sed -i "s/^#?ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/" /etc/ssh/sshd_config
        
        log_info "Изменение MaxAuthTries на 3..."
        sed -i "s/^#?MaxAuthTries .*/MaxAuthTries 3/" /etc/ssh/sshd_config
        
        log_info "Изменение MaxStartups на 10:30:60..."
        sed -i "s/^#?MaxStartups .*/MaxStartups 10:30:60/" /etc/ssh/sshd_config
        
        log_info "Новый порт в конфигурации SSH (после изменения):"
        grep -E "^#?Port" /etc/ssh/sshd_config || echo "Строка Port не найдена"
        
        log_info "Полное содержимое файла конфигурации SSH (после изменения):"
        cat /etc/ssh/sshd_config
    fi
    
    # Шаг 5: Валидация конфигурации SSH перед перезапуском
    log_step "Валидация конфигурации SSH"
    if ! validate_ssh_config; then
        log_error "❌ Конфигурация SSH содержит ошибки. Отмена изменений."
        log_error "Резервная копия сохранена в: /root/.ssh-backups/"
        exit 1
    fi
    
    # Шаг 6: Перезапуск службы SSH
    log_step "Перезапуск службы SSH"
    log_warn "${STYLE_BOLD}⚠️ ВНИМАНИЕ: Порт SSH будет изменен на $port!${COLOR_RESET}"
    log_warn "Убедитесь, что этот порт открыт в файрволе вашего облачного провайдера!"
    
    if [[ "$DRY_RUN" != "true" ]]; then
        log_info "Проверка состояния службы SSH перед перезапуском:"
        systemctl status sshd 2>/dev/null || systemctl status ssh 2>/dev/null || echo "Служба SSH не найдена"
        
        log_info "Попытка перезапуска службы SSH (sshd)..."
        if systemctl restart sshd 2>&1; then
            log_success "✅ Сервис SSH (sshd) перезапущен успешно."
        else
            log_info "Попытка перезапуска службы SSH (ssh)..."
            if systemctl restart ssh 2>&1; then
                log_success "✅ Сервис SSH (ssh) перезапущен успешно."
            else
                log_error "❌ Не удалось перезапустить SSH."
                log_error "Пожалуйста, проверьте конфигурацию:"
                log_error "  sshd -t"
                log_error "  systemctl status ssh"
                log_error "  journalctl -u ssh -n 50"
                log_error ""
                log_error "Резервная копия сохранена в: /root/.ssh-backups/"
                exit 1
            fi
        fi
        
        log_info "Проверка состояния службы SSH после перезапуска:"
        systemctl status sshd 2>/dev/null || systemctl status ssh 2>/dev/null || echo "Служба SSH не найдена"
        
        log_info "Проверка активного порта SSH после перезапуска:"
        if command -v ss &>/dev/null; then
            ss -tuln | grep -E ":(22|$port) " || echo "Порты не найдены"
        else
            netstat -tuln 2>/dev/null | grep -E ":(22|$port) " || echo "Порты не найдены"
        fi
        
        log_success "✅ Сервис SSH перезапущен. Новый порт: $port."
    fi
    
    # Шаг 7: Проверка состояния SSH после перезапуска
    log_step "Проверка состояния SSH после перезапуска"
    if ! check_ssh_status; then
        log_error "❌ Служба SSH не активна после перезапуска."
        log_error "Резервная копия сохранена в: /root/.ssh-backups/"
        exit 1
    fi
    
    # Шаг 8: Проверка доступности нового порта
    log_step "Проверка доступности нового порта SSH"
    if ! check_ssh_port_accessible "$port" 10; then
        log_warn "⚠️ Порт $port может быть недоступен извне."
        log_warn "Убедитесь, что этот порт открыт в файрволе вашего облачного провайдера."
        log_warn "Если вы потеряете доступ, используйте консоль облачного провайдера для восстановления."
    fi
    
    log_success "✅ Настройка SSH завершена успешно."
    log_info "Подключайтесь к серверу с использованием нового порта:"
    echo -e "  ${COLOR_CYAN}ssh -p $port root@YOUR_SERVER_IP${COLOR_RESET}"
}

harden_system() {
    log_info "Укрепление безопасности и оптимизация ядра (sysctl)..."
    
    KERNEL_CONFIG='# Kernel Hardening for VPN Server
# Anti-spoofing (reverse path filtering)
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1

# Ignore ICMP redirects (prevent MITM attacks)
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.secure_redirects=0
net.ipv4.conf.default.secure_redirects=0
net.ipv6.conf.all.accept_redirects=0
net.ipv6.conf.default.accept_redirects=0

# Do not send ICMP redirects
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0

# Disable source routing (prevent forced routing)
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_source_route=0
net.ipv6.conf.all.accept_source_route=0
net.ipv6.conf.default.accept_source_route=0

# SYN flood protection
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_max_syn_backlog=4096
net.ipv4.tcp_synack_retries=2
net.ipv4.tcp_syn_retries=2

# Log suspicious packets (martians)
net.ipv4.conf.all.log_martians=1
net.ipv4.conf.default.log_martians=1

# Ignore ICMP broadcasts (prevent smurf attacks)
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.icmp_ignore_bogus_error_responses=1

# Disable IPv6 router advertisements
net.ipv6.conf.all.accept_ra=0
net.ipv6.conf.default.accept_ra=0

# Protect against time-wait assassination
net.ipv4.tcp_rfc1337=1'
    
    write_config "/etc/sysctl.d/99-kernel-hardening.conf" "$KERNEL_CONFIG"
    
    if [[ "$DRY_RUN" != "true" ]]; then
        sysctl -p /etc/sysctl.d/99-kernel-hardening.conf >/dev/null 2>&1
        log_success "Защита ядра включена."
    fi
}

setup_bbr() {
    log_info "Настройка BBR + TCP оптимизации..."
    
    BBR_CONFIG='# Network optimizations
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 33554432
net.ipv4.tcp_wmem=4096 65536 33554432
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_slow_start_after_idle=0'
    
    write_config "/etc/sysctl.d/99-bbr.conf" "$BBR_CONFIG"
    
    if [[ "$DRY_RUN" != "true" ]]; then
        sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1
        BBR_STATUS=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
        log_success "BBR включен: $BBR_STATUS (улучшает скорость VPN до 2-3x)"
    fi
}

setup_network_limits() {
    log_info "Настройка сетевых лимитов (Conntrack)..."
    
    if [[ "$DRY_RUN" != "true" ]]; then
        TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
        
        # Calculate optimal values based on RAM
        CONNTRACK_MAX=$((TOTAL_RAM_MB * 1024 * 5 / 100 / 300))
        [[ $CONNTRACK_MAX -lt 131072 ]] && CONNTRACK_MAX=131072
        [[ $CONNTRACK_MAX -gt 2097152 ]] && CONNTRACK_MAX=2097152
        HASH_SIZE=$((CONNTRACK_MAX / 4))
    else
        CONNTRACK_MAX=262144
        HASH_SIZE=65536
    fi
    
    NETLIMITS_CONFIG="# Network connection limits for VPN
# Calculated based on RAM: max=$CONNTRACK_MAX

# Connection tracking limits
net.netfilter.nf_conntrack_max=$CONNTRACK_MAX
net.nf_conntrack_max=$CONNTRACK_MAX

# Hash table size (conntrack_max / 4)
net.netfilter.nf_conntrack_buckets=$HASH_SIZE

# Timeout optimizations for VPN
net.netfilter.nf_conntrack_tcp_timeout_established=3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
net.netfilter.nf_conntrack_tcp_timeout_close_wait=15
net.netfilter.nf_conntrack_tcp_timeout_fin_wait=30
net.netfilter.nf_conntrack_udp_timeout=30
net.netfilter.nf_conntrack_udp_timeout_stream=60

# Increase local port range
net.ipv4.ip_local_port_range=1024 65535

# Increase socket backlog
net.core.somaxconn=65535
net.core.netdev_max_backlog=65535

# File descriptors
fs.file-max=2097152
fs.nr_open=2097152"
    
    write_config "/etc/sysctl.d/99-netlimits.conf" "$NETLIMITS_CONFIG"
    write_config "/etc/modprobe.d/nf_conntrack.conf" "options nf_conntrack hashsize=$HASH_SIZE"
    
    if [[ "$DRY_RUN" != "true" ]]; then
        modprobe nf_conntrack 2>/dev/null || true
        sysctl -p /etc/sysctl.d/99-netlimits.conf >/dev/null 2>&1
        echo $HASH_SIZE > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true
        log_success "Сетевые лимиты настроены: max=$CONNTRACK_MAX соединений"
    fi
}

setup_logrotate() {
    log_info "Настройка ротации логов (Logrotate)..."
    
    ROTATE_COUNT="${LOG_RETENTION_DAYS:-90}"
    
    # Main VPN/Remnawave logs
    LOGROTATE_VPN="/var/log/remnanode/*.log {
    daily
    rotate $ROTATE_COUNT
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
    dateext
    dateformat -%Y%m%d
}"
    
    write_config "/etc/logrotate.d/remnanode" "$LOGROTATE_VPN"
    
    # VPS Setup logs
    LOGROTATE_SETUP="/var/log/vps-setup.log {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}"
    
    write_config "/etc/logrotate.d/vps-setup" "$LOGROTATE_SETUP"
    
    # Auth logs (SSH attempts) - important for security
    LOGROTATE_AUTH="/var/log/auth.log {
    daily
    rotate $ROTATE_COUNT
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
    dateext
    dateformat -%Y%m%d
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate 2>/dev/null || true
    endscript
}"
    
    write_config "/etc/logrotate.d/auth-custom" "$LOGROTATE_AUTH"
    
    if [[ "$DRY_RUN" != "true" ]]; then
        mkdir -p /var/log/remnanode
        logrotate -d /etc/logrotate.d/remnanode >/dev/null 2>&1 || true
        log_success "Ротация логов настроена: ${ROTATE_COUNT} дней"
    fi
}

create_swap() {
    if [ -f /swapfile ]; then
        log_info "Swap-файл /swapfile уже существует."
        return
    fi
    log_info "Создание и активация swap-файла размером 2GB..."
    if [[ "$DRY_RUN" != "true" ]]; then
        fallocate -l 2G /swapfile
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        echo 'vm.swappiness=10' > /etc/sysctl.d/99-swap.conf
        sysctl -p /etc/sysctl.d/99-swap.conf >/dev/null 2>&1
    fi
    log_success "Swap-файл успешно создан и активирован."
}

install_core_utils() {
    log_info "Установка базовых утилит (htop, mc, curl, wget, git, ncdu, iptables-persistent)..."
    if [[ "$DRY_RUN" != "true" ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y htop mc curl wget git ncdu iptables-persistent >/dev/null 2>&1
    fi
    log_success "Базовые утилиты установлены."
}

install_docker() {
    if command -v docker &> /dev/null; then
        log_info "Docker уже установлен."
    else
        log_info "Установка Docker..."
        if [[ "$DRY_RUN" != "true" ]]; then
            apt-get install -y ca-certificates curl >/dev/null 2>&1
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg -o /etc/apt/keyrings/docker.asc
            chmod a+r /etc/apt/keyrings/docker.asc
            echo \
              "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") \
              $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
              tee /etc/apt/sources.list.d/docker.list > /dev/null
            apt-get update >/dev/null 2>&1
            apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin >/dev/null 2>&1
            systemctl enable docker >/dev/null 2>&1
        fi
        log_success "Docker успешно установлен."
    fi

    if command -v docker-compose &> /dev/null; then
        log_info "Docker Compose уже установлен."
    else
        log_info "Установка Docker Compose..."
        if [[ "$DRY_RUN" != "true" ]]; then
            LATEST_COMPOSE=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
            DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker}
            mkdir -p $DOCKER_CONFIG/cli-plugins
            curl -SL https://github.com/docker/compose/releases/download/$LATEST_COMPOSE/docker-compose-linux-x86_64 -o $DOCKER_CONFIG/cli-plugins/docker-compose
            chmod +x $DOCKER_CONFIG/cli-plugins/docker-compose
            ln -s $DOCKER_CONFIG/cli-plugins/docker-compose /usr/local/bin/docker-compose
        fi
        log_success "Docker Compose $LATEST_COMPOSE успешно установлен."
    fi
}

setup_chrony() {
    log_info "Установка и настройка chrony для синхронизации времени..."
    if [[ "$DRY_RUN" != "true" ]]; then
        apt-get install -y chrony >/dev/null 2>&1
        systemd_setup "chrony" "restart"
    fi
    log_success "Chrony установлен и запущен."
}

setup_unattended_upgrades() {
    log_info "Установка и настройка автоматических обновлений безопасности..."
    if [[ "$DRY_RUN" != "true" ]]; then
        apt-get install -y unattended-upgrades >/dev/null 2>&1
        echo 'Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Package-Blacklist {
};
Unattended-Upgrade::Automatic-Reboot "false";' > /etc/apt/apt.conf.d/50unattended-upgrades
        echo 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";' > /etc/apt/apt.conf.d/20auto-upgrades
    fi
    log_success "Автоматические обновления безопасности настроены."
}

setup_tblocker() {
    log_info "Установка и настройка tblocker..."
    if [[ "$DRY_RUN" != "true" ]]; then
        curl -fsSL https://raw.githubusercontent.com/HiWay-Media/tblocker/main/install.sh | bash
        mkdir -p /opt/tblocker
        cat > /opt/tblocker/config.yaml << EOF
LogFile: "/var/log/remnanode/access.log"
BlockDuration: 10
TorrentTag: "TORRENT"
BlockMode: "iptables"
BypassIPS: ["127.0.0.1", "::1"]
StorageDir: "/opt/tblocker"
EOF
        systemd_setup "tblocker" "restart"
    fi
    log_success "tblocker установлен и запущен с BlockMode: iptables."
}

block_icmp() {
    log_info "Блокировка входящих ICMP-запросов (ping)..."
    if [[ "$DRY_RUN" != "true" ]]; then
        iptables -D INPUT -p icmp --icmp-type echo-request -j DROP 2>/dev/null || true
        iptables -A INPUT -p icmp --icmp-type echo-request -j DROP
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4
        
        # Create systemd service for persistence
        cat > /etc/systemd/system/iptables-restore.service <<'IPTSERVICE'
[Unit]
Description=Restore iptables
Before=network-pre.target
[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
IPTSERVICE
        systemd_setup "iptables-restore.service" "start"
    fi
    log_success "Правило для блокировки ICMP добавлено и сохранено."
}

disable_ipv6() {
    log_info "Полное отключение IPv6..."
    
    IPV6_CONFIG='net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1'
    
    write_config "/etc/sysctl.d/99-disable-ipv6.conf" "$IPV6_CONFIG"
    
    if [[ "$DRY_RUN" != "true" ]]; then
        sysctl -p /etc/sysctl.d/99-disable-ipv6.conf >/dev/null 2>&1
        sed -i 's/GRUB_CMDLINE_LINUX=""/GRUB_CMDLINE_LINUX="ipv6.disable=1"/' /etc/default/grub
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 ipv6.disable=1"/' /etc/default/grub
        update-grub >/dev/null 2>&1
    fi
    
    log_warn "${STYLE_BOLD}⚠️ ВНИМАНИЕ: IPv6 отключен. Требуется перезагрузка для полного применения.${COLOR_RESET}"
    log_warn "После перезагрузки SSH будет доступен только на IPv4."
    log_warn "Если вы потеряете доступ, используйте консоль облачного провайдера для восстановления."
    log_warn "Для восстановления доступа см. TROUBLESHOOTING.md"
    log_success "IPv6 отключен. Требуется перезагрузка для полного применения."
}

set_timezone() {
    local tz=${1:-"Etc/UTC"}
    log_info "Установка временной зоны на $tz..."
    if [[ "$DRY_RUN" != "true" ]]; then
        timedatectl set-timezone "$tz"
    fi
    log_success "Временная зона установлена: $(timedatectl | grep 'Time zone' | awk '{print $3}')"
}

system_cleanup() {
    log_step "Очистка системы"
    
    # Get initial disk usage
    DISK_BEFORE=$(df / --output=used -B1 2>/dev/null | tail -1)
    
    # Clean apt cache
    log_info "Очистка кэша apt..."
    if [[ "$DRY_RUN" != "true" ]]; then
        apt-get clean >/dev/null 2>&1 || true
        apt-get autoclean >/dev/null 2>&1 || true
    fi
    
    # Remove orphaned packages
    log_info "Удаление ненужных пакетов..."
    if [[ "$DRY_RUN" != "true" ]]; then
        apt-get autoremove -y >/dev/null 2>&1 || true
    fi
    
    # Clean old temporary files (older than 7 days)
    log_info "Очистка старых временных файлов..."
    if [[ "$DRY_RUN" != "true" ]]; then
        find /tmp -type f -atime +7 -delete 2>/dev/null || true
        find /var/tmp -type f -atime +7 -delete 2>/dev/null || true
    fi
    
    # Clean old systemd journal (keep only last 100M)
    if command -v journalctl >/dev/null 2>&1; then
        if [[ "$DRY_RUN" != "true" ]]; then
            journalctl --vacuum-size=100M >/dev/null 2>&1 || true
        fi
    fi
    
    # Get final disk usage and calculate freed space
    DISK_AFTER=$(df / --output=used -B1 2>/dev/null | tail -1)
    if [[ -n "$DISK_BEFORE" && -n "$DISK_AFTER" && "$DISK_BEFORE" -gt "$DISK_AFTER" ]]; then
        FREED_BYTES=$((DISK_BEFORE - DISK_AFTER))
        if [[ "$FREED_BYTES" -gt 1073741824 ]]; then
            FREED_HUMAN="$(echo "scale=2; $FREED_BYTES/1073741824" | bc) GB"
        elif [[ "$FREED_BYTES" -gt 1048576 ]]; then
            FREED_HUMAN="$(echo "scale=2; $FREED_BYTES/1048576" | bc) MB"
        else
            FREED_HUMAN="$((FREED_BYTES/1024)) KB"
        fi
        log_success "Очистка завершена: $FREED_HUMAN освобождено"
    else
        log_success "Очистка завершена"
    fi
}

generate_report() {
    log_info "Генерация отчета о настройках..."
    {
        echo "VPS Setup Report - $(date)"
        echo "================================"
        echo "SSH Port: $SSH_PORT"
        echo "BBR: $ENABLE_BBR"
        echo "Kernel Hardening: $ENABLE_KERNEL_HARDENING"
        echo "Network Limits: $ENABLE_NETWORK_LIMITS"
        echo "Logrotate: $ENABLE_LOGROTATE"
        echo "Log Retention: ${LOG_RETENTION_DAYS} days"
        echo "Swap: enabled"
        echo "Docker: enabled"
        echo "Chrony: enabled"
        echo "Auto-updates: enabled"
        echo "Tblocker: $INSTALL_TBLOCKER"
        echo "Block ICMP: $BLOCK_ICMP"
        echo "Disable IPv6: $DISABLE_IPV6"
        echo "================================"
    } > "$REPORT_FILE" 2>/dev/null || true
    log_success "Отчет сохранен: $REPORT_FILE"
}

# --- Интерактивное меню ---

display_menu() {
    clear
    local box_width=63
    
    echo ""
    echo -e "${STYLE_BOLD}╔═══════════════════════════════════════════════════════════════╗${COLOR_RESET}"
    local welcome_msg="Lightweight VPS Setup for Remnawave"
    local welcome_text="🔧 $welcome_msg"
    local welcome_len=$(( ${#welcome_msg} + 3 ))
    local welcome_pad=$(( (box_width - welcome_len) / 2 ))
    printf "${STYLE_BOLD}║%*s%s%*s║${COLOR_RESET}\n" $welcome_pad "" "$welcome_text" $((box_width - welcome_pad - welcome_len)) ""
    echo -e "${STYLE_BOLD}╠═══════════════════════════════════════════════════════════════╣${COLOR_RESET}"
    local beginners_text="Режим для начинающих: каждая опция с объяснением"
    local beginners_len=${#beginners_text}
    local beginners_pad=$(( (box_width - beginners_len) / 2 ))
    printf "${STYLE_BOLD}║${COLOR_RESET}%*s${COLOR_GREEN}%s${COLOR_RESET}%*s${STYLE_BOLD}║${COLOR_RESET}\n" $beginners_pad "" "$beginners_text" $((box_width - beginners_pad - beginners_len)) ""
    echo -e "${STYLE_BOLD}╚═══════════════════════════════════════════════════════════════╝${COLOR_RESET}"
    
    echo ""
    echo "Выберите компоненты для установки. Отметьте желаемые опции [x]."
    echo "Нажмите Enter, чтобы начать установку."
    echo ""

    options=(
        "1:🎓 Настроить безопасный SSH:Изменяет стандартный порт SSH и ужесточает параметры подключения для защиты от ботов.:on"
        "2:🎓 Укрепить и оптимизировать систему:Применяет базовые параметры безопасности ядра, создает swap и настраивает время.:on"
        "3:🎓 Установить Docker и утилиты:Устанавливает Docker, Docker Compose и основной набор утилит для администрирования.:on"
        "4:🎓 Включить BBR (ускорение VPN):Алгоритм управления сетью от Google. Значительно улучшает скорость и стабильность VPN (до 2-3x быстрее).:on"
        "5:🎓 Настроить сетевые лимиты:Увеличивает лимиты отслеживания соединений для VPN с 100+ пользователями.:on"
        "6:🎓 Настроить ротацию логов:Автоматическая очистка логов для предотвращения переполнения диска.:on"
        "7:🎓 Установить tblocker:Блокирует подключения к торрент-трекерам на уровне iptables.:off"
        "8:🎓 Заблокировать ICMP (ping):Блокирует входящие ICMP-запросы для скрытия сервера от простого сканирования.:off"
        "9:🎓 Отключить IPv6:Полностью отключает протокол IPv6 на уровне ядра и загрузчика.:off"
    )

    for i in "${!options[@]}"; do
        state=$(echo "${options[i]}" | cut -d: -f3)
        if [ "$state" == "on" ]; then
            checkbox="[x]"
        else
            checkbox="[ ]"
        fi
        desc=$(echo "${options[i]}" | cut -d: -f2)
        item=$(echo "${options[i]}" | cut -d: -f1)
        echo -e " ${STYLE_BOLD}$item${COLOR_RESET} $checkbox $desc"
    done

    echo ""
    echo "Введите номер пункта, чтобы изменить его статус, или нажмите Enter для старта."
    
    while true; do
        read -r -p "Ваш выбор: " local choice
        case $choice in
            [1-9])
                idx=$((choice-1))
                state=$(echo "${options[idx]}" | cut -d: -f3)
                if [ "$state" == "on" ]; then
                    options[idx]=$(echo "${options[idx]}" | sed 's/:on/:off/')
                else
                    options[idx]=$(echo "${options[idx]}" | sed 's/:off/:on/')
                fi
                clear
                display_menu
                ;;
            "")
                break
                ;;
            *)
                log_warn "Неверный ввод. Пожалуйста, выберите номер от 1 до 9 или нажмите Enter."
                ;;
        esac
    done

    # Установка на основе выбора
    for i in "${!options[@]}"; do
        state=$(echo "${options[i]}" | cut -d: -f3)
        if [ "$state" == "on" ]; then
            case $((i+1)) in
                1) INTERACTIVE_SSH="true" ;;
                2) INTERACTIVE_HARDEN="true" ;;
                3) INTERACTIVE_DOCKER="true" ;;
                4) INTERACTIVE_BBR="true" ;;
                5) INTERACTIVE_NETLIMITS="true" ;;
                6) INTERACTIVE_LOGROTATE="true" ;;
                7) INSTALL_TBLOCKER="true" ;;
                8) BLOCK_ICMP="true" ;;
                9) DISABLE_IPV6="true" ;;
            esac
        fi
    done
}

# --- Главная функция ---

main() {
    check_root
    check_os

    # Create log directory
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "=== VPS Setup $(date) ===" >> "$LOG_FILE"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo ""
        log_warn "РЕЖИМ DRY-RUN: Изменения не применяются"
    fi

    # Проверка на неинтерактивный режим
    if [[ -n "$SSH_PORT" || -n "$INSTALL_TBLOCKER" || -n "$BLOCK_ICMP" || -n "$DISABLE_IPV6" || -n "$TIMEZONE" ]]; then
        log_info "Обнаружены переменные окружения. Запуск в неинтерактивном режиме."

        update_system
        install_core_utils
        
        # Обязательные компоненты
        setup_ssh "${SSH_PORT:-2222}"
        
        if [[ "$ENABLE_KERNEL_HARDENING" == "true" ]]; then
            harden_system
        fi
        
        create_swap
        setup_chrony
        setup_unattended_upgrades
        install_docker
        
        # Опциональные компоненты
        [[ "$ENABLE_BBR" == "true" ]] && setup_bbr
        [[ "$ENABLE_NETWORK_LIMITS" == "true" ]] && setup_network_limits
        [[ "$ENABLE_LOGROTATE" == "true" ]] && setup_logrotate
        [ -n "$TIMEZONE" ] && set_timezone "$TIMEZONE"
        [ "$INSTALL_TBLOCKER" == "true" ] && setup_tblocker
        [ "$BLOCK_ICMP" == "true" ] && block_icmp
        [ "$DISABLE_IPV6" == "true" ] && disable_ipv6
        
        # Очистка системы
        [[ "$ENABLE_CLEANUP" == "true" ]] && system_cleanup
        
        # Генерация отчета
        generate_report

    else
        # Интерактивный режим
        display_menu
        
        log_info "Начало установки на основе вашего выбора..."
        
        update_system
        install_core_utils

        if [ "$INTERACTIVE_SSH" == "true" ]; then
            local suggested_port=$(generate_random_port)
            echo -e "${COLOR_BLUE}ℹ${COLOR_RESET}  ${COLOR_CYAN}Предложенный случайный порт: ${COLOR_GREEN}$suggested_port${COLOR_RESET}"
            read -r -p "Введите новый порт для SSH (по умолчанию $suggested_port): " user_port
            
            # Валидация введенного порта
            while ! validate_port "$user_port"; do
                log_error "Некорректный порт. Введите число от 1024 до 65535."
                read -r -p "Введите новый порт для SSH: " user_port
            done
            
            setup_ssh "${user_port:-$suggested_port}"
        fi

        if [ "$INTERACTIVE_HARDEN" == "true" ]; then
            harden_system
            create_swap
            setup_chrony
            setup_unattended_upgrades
        fi

        if [ "$INTERACTIVE_DOCKER" == "true" ]; then
            install_docker
        fi

        if [ "$INTERACTIVE_BBR" == "true" ]; then
            setup_bbr
        fi

        if [ "$INTERACTIVE_NETLIMITS" == "true" ]; then
            setup_network_limits
        fi

        if [ "$INTERACTIVE_LOGROTATE" == "true" ]; then
            setup_logrotate
        fi

        [ "$INSTALL_TBLOCKER" == "true" ] && setup_tblocker
        [ "$BLOCK_ICMP" == "true" ] && block_icmp
        [ "$DISABLE_IPV6" == "true" ] && disable_ipv6
        
        # Очистка системы
        system_cleanup
        
        # Генерация отчета
        generate_report
    fi

    # Финальный отчет
    echo ""
    echo -e "${STYLE_BOLD}╔═══════════════════════════════════════════════════════════════╗${COLOR_RESET}"
    local complete_msg="НАСТРОЙКА ЗАВЕРШЕНА"
    local complete_text="📊 $complete_msg"
    local complete_len=$(( ${#complete_msg} + 3 ))
    local complete_pad=$(( (63 - complete_len) / 2 ))
    printf "${STYLE_BOLD}║%*s%s%*s║${COLOR_RESET}\n" $complete_pad "" "$complete_text" $((63 - complete_pad - complete_len)) ""
    echo -e "${STYLE_BOLD}╚═══════════════════════════════════════════════════════════════╝${COLOR_RESET}"
    echo ""
    echo -e "  🔐 SSH Port:          ${COLOR_GREEN}$SSH_PORT${COLOR_RESET}"
    [[ "$ENABLE_BBR" == "true" ]] && echo -e "  🚀 BBR:               ${COLOR_GREEN}включен${COLOR_RESET}"
    [[ "$ENABLE_KERNEL_HARDENING" == "true" ]] && echo -e "  🔒 Kernel Hardening:   ${COLOR_GREEN}включен${COLOR_RESET}"
    [[ "$ENABLE_NETWORK_LIMITS" == "true" ]] && echo -e "  📊 Network Limits:     ${COLOR_GREEN}включен${COLOR_RESET}"
    [[ "$ENABLE_LOGROTATE" == "true" ]] && echo -e "  📝 Logrotate:         ${COLOR_GREEN}включен${COLOR_RESET}"
    echo -e "  🐳 Docker:            ${COLOR_GREEN}установлен${COLOR_RESET}"
    echo -e "  ⏰ Chrony:            ${COLOR_GREEN}установлен${COLOR_RESET}"
    echo -e "  🔄 Auto-updates:      ${COLOR_GREEN}включены${COLOR_RESET}"
    echo -e "  🧹 Cleanup:           ${COLOR_GREEN}выполнена${COLOR_RESET}"
    echo ""
    echo -e "  📋 Полезные команды:"
    echo -e "     ${COLOR_CYAN}ssh -p $SSH_PORT root@YOUR_SERVER${COLOR_RESET}"
    echo -e "     ${COLOR_CYAN}cat $REPORT_FILE${COLOR_RESET}"
    echo ""

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "РЕЖИМ DRY-RUN: Изменения не применены"
    else
        echo -e "${COLOR_GREEN}${STYLE_BOLD}✅ Сервер успешно настроен!${COLOR_RESET}"
    fi

    log_warn "Рекомендуется перезагрузить сервер для применения всех изменений (особенно отключения IPv6 и BBR)."
}

main "$@"
