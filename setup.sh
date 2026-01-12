#!/bin/bash

################################################################################
# Lightweight VPS Setup for Remnawave
# Version: 1.13.0
# Author: mvrvntn
# Description: Automated VPS setup script for Debian/Ubuntu systems
#              Compatible with remnawave-reverse-proxy and bbr3
################################################################################

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script version
SCRIPT_VERSION="1.13.0"

################################################################################
# Configuration Variables
################################################################################

# Default SSH port (kept for compatibility, but not used)
SSH_PORT="${SSH_PORT:-2222}"

# Optional features (default: false)
INSTALL_TBLOCKER="${INSTALL_TBLOCKER:-false}"
BLOCK_ICMP="${BLOCK_ICMP:-false}"
DISABLE_IPV6="${DISABLE_IPV6:-false}"
CONFIGURE_DNS="${CONFIGURE_DNS:-false}"

# Timezone
TIMEZONE="${TIMEZONE:-Etc/UTC}"

# Conflict warning controls (default: true)
WARN_TBLOCKER_CONFLICT="${WARN_TBLOCKER_CONFLICT:-true}"
WARN_ICMP_CONFLICT="${WARN_ICMP_CONFLICT:-true}"
WARN_IPV6_CONFLICT="${WARN_IPV6_CONFLICT:-true}"

# Network settings
CONNTRACK_TIMEOUT="${CONNTRACK_TIMEOUT:-7200}"
ENABLE_KERNEL_HARDENING="${ENABLE_KERNEL_HARDENING:-true}"
ENABLE_NETWORK_LIMITS="${ENABLE_NETWORK_LIMITS:-true}"

# System maintenance
ENABLE_LOGROTATE="${ENABLE_LOGROTATE:-true}"
ENABLE_CLEANUP="${ENABLE_CLEANUP:-true}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"

# Dry run mode
DRY_RUN="${DRY_RUN:-false}"

# Detect if running in non-interactive mode
NON_INTERACTIVE=false
if [ -n "$SSH_PORT" ] || [ -n "$INSTALL_TBLOCKER" ] || [ -n "$BLOCK_ICMP" ] || [ -n "$DISABLE_IPV6" ] || [ -n "$TIMEZONE" ] || [ -n "$CONFIGURE_DNS" ]; then
    NON_INTERACTIVE=true
fi

################################################################################
# Helper Functions
################################################################################

print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "Этот скрипт должен быть запущен от имени root"
        print_info "Используйте: sudo bash $0"
        exit 1
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    else
        print_error "Не удалось определить операционную систему"
        exit 1
    fi

    case "$OS:$VERSION" in
        debian:11|debian:12|ubuntu:20.04|ubuntu:22.04|ubuntu:24.04)
            print_success "Обнаружена совместимая ОС: $PRETTY_NAME"
            ;;
        *)
            print_error "Неподдерживаемая ОС: $PRETTY_NAME"
            print_info "Поддерживаемые версии: Debian 11/12, Ubuntu 20.04/22.04/24.04"
            exit 1
            ;;
    esac
}

################################################################################
# Core Functions
################################################################################

configure_ssh() {
    print_header "🎓 Настройка безопасного SSH"
    print_info "Изменение стандартного порта SSH и ужесточение параметров подключения для защиты от ботов."

    SSH_CONFIG="/etc/ssh/sshd_config"
    BACKUP_FILE="/etc/ssh/sshd_config.backup.$(date +%Y%m%d%H%M%S)"

    # Backup original config
    cp "$SSH_CONFIG" "$BACKUP_FILE"
    print_info "Создана резервная копия: $BACKUP_FILE"

    # Configure SSH
    sed -i "s/^#*Port .*/Port $SSH_PORT/" "$SSH_CONFIG"
    sed -i "s/^#*PermitRootLogin .*/PermitRootLogin yes/" "$SSH_CONFIG"
    sed -i "s/^#*PasswordAuthentication .*/PasswordAuthentication yes/" "$SSH_CONFIG"
    sed -i "s/^#*ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/" "$SSH_CONFIG"
    sed -i "s/^#*MaxAuthTries .*/MaxAuthTries 3/" "$SSH_CONFIG"
    sed -i "s/^#*MaxStartups .*/MaxStartups 10:30:60/" "$SSH_CONFIG"

    # Ensure settings are present
    if ! grep -q "^Port " "$SSH_CONFIG"; then
        echo "Port $SSH_PORT" >> "$SSH_CONFIG"
    fi
    if ! grep -q "^PermitRootLogin " "$SSH_CONFIG"; then
        echo "PermitRootLogin yes" >> "$SSH_CONFIG"
    fi
    if ! grep -q "^PasswordAuthentication " "$SSH_CONFIG"; then
        echo "PasswordAuthentication yes" >> "$SSH_CONFIG"
    fi
    if ! grep -q "^ChallengeResponseAuthentication " "$SSH_CONFIG"; then
        echo "ChallengeResponseAuthentication no" >> "$SSH_CONFIG"
    fi
    if ! grep -q "^MaxAuthTries " "$SSH_CONFIG"; then
        echo "MaxAuthTries 3" >> "$SSH_CONFIG"
    fi
    if ! grep -q "^MaxStartups " "$SSH_CONFIG"; then
        echo "MaxStartups 10:30:60" >> "$SSH_CONFIG"
    fi

    # Test SSH configuration
    if sshd -t 2>/dev/null; then
        print_success "Конфигурация SSH проверена успешно"
    else
        print_error "Ошибка в конфигурации SSH"
        print_info "Восстановление из резервной копии..."
        cp "$BACKUP_FILE" "$SSH_CONFIG"
        exit 1
    fi

    # Restart SSH service
    systemctl restart sshd || systemctl restart ssh
    print_success "SSH сервис перезапущен"

    print_warning ""
    print_warning "═══════════════════════════════════════════════════════════════"
    print_warning "⚠ ВАЖНОЕ ПРЕДУПРЕЖДЕНИЕ: Порт SSH изменен на $SSH_PORT"
    print_warning "═══════════════════════════════════════════════════════════════"
    print_warning ""
    print_warning "Перед отключением от сервера выполните следующие действия:"
    print_warning "1. Откройте новый порт $SSH_PORT в файрволе вашего облачного провайдера"
    print_warning "2. Проверьте подключение по новому порту в новом терминале:"
    print_warning "   ssh root@YOUR_SERVER_IP -p $SSH_PORT"
    print_warning "3. Только после успешного подключения закройте этот терминал"
    print_warning ""
    print_warning "Если вы не откроете порт $SSH_PORT, вы потеряете доступ к серверу!"
    print_warning "═══════════════════════════════════════════════════════════════"
    print_warning ""
}

harden_system() {
    print_header "🎓 Укрепление и оптимизация системы"
    print_info "Применение базовых параметров безопасности ядра и оптимизация сетевых настроек."

    SYSCTL_FILE="/etc/sysctl.d/99-vps-security.conf"

    cat > "$SYSCTL_FILE" <<EOF
# IP Spoofing protection
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# SYN cookies protection
net.ipv4.tcp_syncookies = 1

# Ignore ICMP broadcast requests
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Ignore bogus ICMP errors
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Log martian packets
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Shared memory
kernel.shmmax = 68719476736
kernel.shmall = 4294967296

# File handles
fs.file-max = 2097152

# Swap usage
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 3

# Network optimization
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_keepalive_intvl = 15
EOF

    if [ "$ENABLE_KERNEL_HARDENING" = "true" ]; then
        cat >> "$SYSCTL_FILE" <<EOF

# Additional kernel hardening
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.perf_event_paranoid = 2
EOF
    fi

    if [ "$ENABLE_NETWORK_LIMITS" = "true" ]; then
        cat >> "$SYSCTL_FILE" <<EOF

# Connection tracking limits (optimized for 100+ users)
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = $CONNTRACK_TIMEOUT
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
EOF
    fi

    # Apply sysctl settings
    sysctl -p "$SYSCTL_FILE" > /dev/null 2>&1 || sysctl --system > /dev/null 2>&1
    print_success "Настройки ядра применены"
}

create_swap() {
    print_header "🎓 Создание swap-файла"
    print_info "Создание и активация swap-файла размером 2GB для улучшения производительности."

    SWAP_FILE="/swapfile"
    SWAP_SIZE="2G"

    # Check if swap already exists
    if [ -f "$SWAP_FILE" ] || swapon --show | grep -q "$SWAP_FILE"; then
        print_info "Swap-файл уже существует"
        return
    fi

    # Create swap file
    fallocate -l "$SWAP_SIZE" "$SWAP_FILE"
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE"
    swapon "$SWAP_FILE"

    # Add to fstab if not already present
    if ! grep -q "$SWAP_FILE" /etc/fstab; then
        echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
    fi

    # Configure swappiness
    sysctl vm.swappiness=10
    echo "vm.swappiness=10" >> /etc/sysctl.conf

    print_success "Swap-файл создан и активирован"
}

setup_chrony() {
    print_header "🎓 Настройка синхронизации времени"
    print_info "Установка и настройка chrony для точной синхронизации времени сервера."

    # Install chrony
    apt-get update -qq
    apt-get install -y chrony

    # Configure timezone
    timedatectl set-timezone "$TIMEZONE"

    # Configure chrony
    cat > /etc/chrony/chrony.conf <<EOF
# Use public servers from the pool.ntp.org project.
pool pool.ntp.org iburst

# Record the rate at which the system clock gains/losses time.
driftfile /var/lib/chrony/drift

# Allow the system clock to be stepped in the first three updates.
makestep 1.0 3

# Enable kernel RTC synchronization.
rtcsync

# Serve time even if not synchronized to a time source.
# local stratum 10
EOF

    # Restart chrony
    systemctl enable chrony
    systemctl restart chrony

    print_success "Chrony настроен и запущен"
    print_info "Часовой пояс установлен: $TIMEZONE"
}

setup_unattended_upgrades() {
    print_header "🎓 Настройка автоматических обновлений"
    print_info "Установка и настройка unattended-upgrades для автоматической установки обновлений безопасности."

    # Install unattended-upgrades
    apt-get update -qq
    apt-get install -y unattended-upgrades

    # Configure unattended-upgrades
    cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}";
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}ESMApps:\${distro_codename}-apps-security";
    "\${distro_id}ESM:\${distro_codename}-infra-security";
};

Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "02:00";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Mail "root";
Unattended-Upgrade::MailOnlyOnError "true";
Unattended-Upgrade::Verbose "false";
Unattended-Upgrade::Debug "false";
EOF

    # Enable auto updates
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

    # Enable and start service
    systemctl enable unattended-upgrades
    systemctl start unattended-upgrades

    print_success "Автоматические обновления настроены"
}

install_docker() {
    print_header "🎓 Установка Docker и Docker Compose"
    print_info "Установка последней версии Docker и Docker Compose для контейнеризации приложений."

    # Remove old versions
    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

    # Install dependencies
    apt-get update -qq
    apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release

    # Add Docker's official GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$OS/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Set up the repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Install Docker Engine
    apt-get update -qq
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Enable and start Docker
    systemctl enable docker
    systemctl start docker

    # Add current user to docker group if not root
    if [ -n "$SUDO_USER" ]; then
        usermod -aG docker "$SUDO_USER"
        print_info "Пользователь $SUDO_USER добавлен в группу docker"
    fi

    print_success "Docker и Docker Compose установлены"
    docker --version
    docker compose version
}

install_utilities() {
    print_header "🎓 Установка базовых утилит"
    print_info "Установка набора утилит для администрирования и мониторинга сервера."

    apt-get update -qq
    apt-get install -y \
        htop \
        mc \
        curl \
        wget \
        git \
        ncdu \
        iptables-persistent \
        vim \
        net-tools \
        dnsutils \
        unzip \
        jq

    print_success "Базовые утилиты установлены"
}

setup_logrotate() {
    print_header "🎓 Настройка ротации логов"
    print_info "Настройка logrotate для автоматического управления лог-файлами."

    cat > /etc/logrotate.d/vps-custom <<EOF
# Custom logrotate configuration for VPS
/var/log/*.log {
    daily
    rotate $LOG_RETENTION_DAYS
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
    sharedscripts
    postrotate
        systemctl reload rsyslog > /dev/null 2>&1 || true
    endscript
}

/var/log/docker/*.log {
    daily
    rotate $LOG_RETENTION_DAYS
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
}
EOF

    print_success "Ротация логов настроена"
}

cleanup_system() {
    print_header "🎓 Очистка системы"
    print_info "Удаление ненужных пакетов и очистка кэша для освобождения дискового пространства."

    # Remove unnecessary packages
    apt-get autoremove -y
    apt-get autoclean -y
    apt-get clean

    # Clean journal logs
    journalctl --vacuum-time=7d

    print_success "Система очищена"
}

################################################################################
# Optional Functions
################################################################################

install_tblocker() {
    print_header "🎓 Установка tblocker"
    print_info "Установка и настройка tblocker для блокировки торрент-трафика."

    if [ "$WARN_TBLOCKER_CONFLICT" = "true" ]; then
        print_warning ""
        print_warning "═══════════════════════════════════════════════════════════════"
        print_warning "⚠ ПРЕДУПРЕЖДЕНИЕ О КОНФЛИКТЕ"
        print_warning "═══════════════════════════════════════════════════════════════"
        print_warning "tblocker использует iptables для блокировки трафика."
        print_warning "Это может конфликтовать с:"
        print_warning "  - remnawave-reverse-proxy (если использует iptables)"
        print_warning "  - bbr3 (если использует iptables)"
        print_warning ""
        print_warning "Если вы планируете использовать эти проекты, установите"
        print_warning "tblocker ПОСЛЕ них или настройте исключения вручную."
        print_warning "═══════════════════════════════════════════════════════════════"
        print_warning ""
    fi

    # Install tblocker
    apt-get update -qq
    apt-get install -y tblocker

    # Create config directory
    mkdir -p /opt/tblocker

    # Create configuration
    cat > /opt/tblocker/config.yaml <<EOF
# tblocker configuration
BlockMode: iptables
LogLevel: info
UpdateInterval: 24h
EOF

    # Enable and start tblocker
    systemctl enable tblocker
    systemctl restart tblocker

    print_success "tblocker установлен и настроен"
}

block_icmp() {
    print_header "🎓 Блокировка ICMP"
    print_info "Добавление правила iptables для блокировки входящих ICMP-запросов (ping)."

    if [ "$WARN_ICMP_CONFLICT" = "true" ]; then
        print_warning ""
        print_warning "═══════════════════════════════════════════════════════════════"
        print_warning "⚠ ПРЕДУПРЕЖДЕНИЕ О КОНФЛИКТЕ"
        print_warning "═══════════════════════════════════════════════════════════════"
        print_warning "Блокировка ICMP может нарушить работу:"
        print_warning "  - remnawave-reverse-proxy (если использует ICMP)"
        print_warning "  - bbr3 (если использует ICMP)"
        print_warning ""
        print_warning "Это также сделает сервер недоступным для ping-запросов,"
        print_warning "что может усложнить диагностику сетевых проблем."
        print_warning "═══════════════════════════════════════════════════════════════"
        print_warning ""
    fi

    # Add ICMP blocking rule
    iptables -A INPUT -p icmp --icmp-type echo-request -j DROP

    # Save iptables rules
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4

    # Ensure iptables-persistent is enabled
    systemctl enable netfilter-persistent

    print_success "ICMP заблокирован"
}

disable_ipv6() {
    print_header "🎓 Отключение IPv6"
    print_info "Полное отключение IPv6 на уровне ядра и загрузчика."

    if [ "$WARN_IPV6_CONFLICT" = "true" ]; then
        print_warning ""
        print_warning "═══════════════════════════════════════════════════════════════"
        print_warning "⚠ ПРЕДУПРЕЖДЕНИЕ О КОНФЛИКТЕ"
        print_warning "═══════════════════════════════════════════════════════════════"
        print_warning "Отключение IPv6 может нарушить работу:"
        print_warning "  - remnawave-reverse-proxy (если использует IPv6)"
        print_warning "  - bbr3 (если использует IPv6)"
        print_warning ""
        print_warning "Убедитесь, что ваши приложения не требуют IPv6 перед"
        print_warning "отключением этой функции."
        print_warning "═══════════════════════════════════════════════════════════════"
        print_warning ""
    fi

    # Disable IPv6 via sysctl
    cat > /etc/sysctl.d/99-disable-ipv6.conf <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

    # Apply sysctl settings
    sysctl -p /etc/sysctl.d/99-disable-ipv6.conf > /dev/null 2>&1

    # Disable IPv6 in GRUB
    if [ -f /etc/default/grub ]; then
        if ! grep -q "ipv6.disable=1" /etc/default/grub; then
            sed -i 's/GRUB_CMDLINE_LINUX=""/GRUB_CMDLINE_LINUX="ipv6.disable=1"/' /etc/default/grub
            update-grub > /dev/null 2>&1
        fi
    fi

    print_success "IPv6 отключен"
}

configure_dns() {
    print_header "🎓 Настройка DNS"
    print_info "Настройка DNS-серверов с автоматическим выбором оптимальных серверов."

    # Backup current resolv.conf
    RESOLV_CONF="/etc/resolv.conf"
    RESOLV_BACKUP="/etc/resolv.conf.backup.$(date +%Y%m%d%H%M%S)"
    
    if [ -f "$RESOLV_CONF" ]; then
        cp "$RESOLV_CONF" "$RESOLV_BACKUP"
        print_info "Создана резервная копия: $RESOLV_BACKUP"
    fi

    # DNS servers hierarchy
    # Primary: Cloudflare DNS over TLS/HTTPS
    DOT_SERVER="5u35p8m9i7.cloudflare-gateway.com"
    DOH_URL="https://5u35p8m9i7.cloudflare-gateway.com/dns-query"
    
    # Secondary: IPv4 DNS servers
    IPV4_DNS_PRIMARY="84.21.189.133"
    IPV4_DNS_SECONDARY="193.23.209.189"
    
    # Tertiary: Fallback DNS servers
    FALLBACK_DOH_URL="https://dns.comss.one/dns-query"
    FALLBACK_IPV4_PRIMARY="83.220.169.155"
    FALLBACK_IPV4_SECONDARY="212.109.195.93"

    # Detect if we can use systemd-resolved (supports DoT/DoH)
    USE_SYSTEMD_RESOLVED=false
    if [ -f /etc/systemd/resolved.conf ] && systemctl is-active --quiet systemd-resolved; then
        USE_SYSTEMD_RESOLVED=true
        print_info "Обнаружен systemd-resolved - используется DNS over TLS"
    fi

    # Detect if we can use stubby (DoT client)
    USE_STUBBY=false
    if command -v stubby &> /dev/null; then
        USE_STUBBY=true
        print_info "Обнаружен stubby - используется DNS over TLS"
    fi

    # Configure DNS based on available options
    if [ "$USE_SYSTEMD_RESOLVED" = "true" ]; then
        # Configure systemd-resolved with DoT
        cat > /etc/systemd/resolved.conf <<EOF
[Resolve]
# Cloudflare DNS over TLS
DNS=${IPV4_DNS_PRIMARY} ${IPV4_DNS_SECONDARY}
FallbackDNS=${FALLBACK_IPV4_PRIMARY} ${FALLBACK_IPV4_SECONDARY}
# DoT configuration
DNSOverTLS=yes
DNS=${DOT_SERVER}
EOF
        
        # Restart systemd-resolved
        systemctl restart systemd-resolved
        
        # Update symlink to use systemd-resolved
        if [ -L "$RESOLV_CONF" ]; then
            rm "$RESOLV_CONF"
        fi
        ln -sf /run/systemd/resolve/stub-resolv.conf "$RESOLV_CONF"
        
        print_success "DNS настроен через systemd-resolved с DoT"
        
    elif [ "$USE_STUBBY" = "true" ]; then
        # Configure stubby with DoT
        mkdir -p /etc/stubby
        
        cat > /etc/stubby/stubby.yml <<EOF
resolution_type: GETDNS_RESOLUTION_STUB
round_robin_upstreams: true
listen_addresses:
  - 127.0.0.1
  - 0::1
dns_transport_list:
  - GETDNS_TRANSPORT_TLS
tls_authentication: GETDNS_AUTHENTICATION_REQUIRED
tls_query_padding_blocksize: 128
edns_client_subnet:
  - 0.0.0.0/0
upstream_recursive_servers:
  - address_data: ${DOT_SERVER}
    tls_auth_name: "${DOT_SERVER}"
    tls_port: 853
  - address_data: ${IPV4_DNS_PRIMARY}
  - address_data: ${IPV4_DNS_SECONDARY}
  - address_data: ${FALLBACK_IPV4_PRIMARY}
  - address_data: ${FALLBACK_IPV4_SECONDARY}
EOF
        
        # Restart stubby
        systemctl enable stubby
        systemctl restart stubby
        
        # Update resolv.conf to use stubby
        cat > "$RESOLV_CONF" <<EOF
# DNS configuration by vps-setup
# Using stubby for DNS over TLS
nameserver 127.0.0.1
nameserver ::1
options timeout:2 attempts:3 rotate single-request-reopen
EOF
        
        print_success "DNS настроен через stubby с DoT"
        
    else
        # Fallback to traditional DNS configuration
        print_info "Используется традиционная конфигурация DNS"
        
        # Create new resolv.conf
        cat > "$RESOLV_CONF" <<EOF
# DNS configuration by vps-setup
# Primary DNS servers
nameserver ${IPV4_DNS_PRIMARY}
nameserver ${IPV4_DNS_SECONDARY}

# Fallback DNS servers
nameserver ${FALLBACK_IPV4_PRIMARY}
nameserver ${FALLBACK_IPV4_SECONDARY}

options timeout:2 attempts:3 rotate single-request-reopen
options edns0
EOF
        
        # Prevent DHCP from overwriting resolv.conf
        if [ -f /etc/dhcp/dhclient.conf ]; then
            if ! grep -q "supersede domain-name-servers" /etc/dhcp/dhclient.conf; then
                echo "supersede domain-name-servers ${IPV4_DNS_PRIMARY}, ${IPV4_DNS_SECONDARY};" >> /etc/dhcp/dhclient.conf
            fi
        fi
        
        # For NetworkManager
        if [ -f /etc/NetworkManager/NetworkManager.conf ]; then
            if ! grep -q "dns=none" /etc/NetworkManager/NetworkManager.conf; then
                sed -i '/^\[main\]/a dns=none' /etc/NetworkManager/NetworkManager.conf
            fi
        fi
        
        print_success "DNS настроен с использованием IPv4-адресов"
    fi

    # Test DNS configuration
    print_info "Проверка DNS-конфигурации..."
    
    if command -v nslookup &> /dev/null; then
        if nslookup google.com > /dev/null 2>&1; then
            print_success "DNS работает корректно"
        else
            print_warning "DNS может не работать корректно. Проверьте конфигурацию."
        fi
    fi

    print_info ""
    print_info "Используемые DNS-серверы:"
    print_info "  • Основной (DoT): ${DOT_SERVER}"
    print_info "  • Основной (IPv4): ${IPV4_DNS_PRIMARY}"
    print_info "  • Резервный (IPv4): ${IPV4_DNS_SECONDARY}"
    print_info "  • Fallback (DoH): ${FALLBACK_DOH_URL}"
    print_info "  • Fallback (IPv4): ${FALLBACK_IPV4_PRIMARY}, ${FALLBACK_IPV4_SECONDARY}"
}

################################################################################
# Interactive Menu
################################################################################

show_menu() {
    clear
    echo -e "${BLUE}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║   Lightweight VPS Setup for Remnawave v$SCRIPT_VERSION            ║"
    echo "║   Автор: mvrvntn                                               ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    echo "🎓 Выберите компоненты для установки:"
    echo ""
    echo "  [1] 🎓 Настроить безопасный SSH - Изменяет стандартный порт SSH и ужесточает параметры подключения для защиты от ботов."
    echo "  [2] 🎓 Укрепить систему - Применяет параметры безопасности ядра и оптимизирует сетевые настройки."
    echo "  [3] 🎓 Создать swap-файл - Создает swap-файл 2GB для улучшения производительности."
    echo "  [4] 🎓 Настроить время - Устанавливает chrony для точной синхронизации времени."
    echo "  [5] 🎓 Автообновления - Настраивает автоматические обновления безопасности."
    echo "  [6] 🎓 Установить Docker - Устанавливает Docker и Docker Compose."
    echo "  [7] 🎓 Установить утилиты - Устанавливает базовые утилиты для администрирования."
    echo "  [8] 🎓 Установить tblocker - Блокирует торрент-трафик (опционально)."
    echo "  [9] 🎓 Блокировать ICMP - Блокирует ping-запросы (опционально)."
    echo " [10] 🎓 Отключить IPv6 - Полностью отключает IPv6 (опционально)."
    echo " [11] 🎓 Настроить DNS - Настраивает DNS-серверы с автоматическим выбором оптимальных (опционально)."
    echo " [12] 🎓 Установить всё - Устанавливает все обязательные компоненты."
    echo " [13] 🎓 Полная настройка - Устанавливает все компоненты включая опциональные."
    echo ""
    echo "  [0] 🎓 Выход"
    echo ""
    echo -n "Ваш выбор: "
}

run_interactive() {
    while true; do
        show_menu
        read -r choice

        case $choice in
                1)
                    # configure_ssh # Disabled - kept for compatibility
                    print_info "Настройка SSH отключена"
                    ;;
            2)
                harden_system
                ;;
            3)
                create_swap
                ;;
            4)
                setup_chrony
                ;;
            5)
                setup_unattended_upgrades
                ;;
            6)
                install_docker
                ;;
            7)
                install_utilities
                ;;
            8)
                install_tblocker
                ;;
            9)
                block_icmp
                ;;
            10)
                disable_ipv6
                ;;
            11)
                configure_dns
                ;;
            12)
                harden_system
                create_swap
                setup_chrony
                setup_unattended_upgrades
                install_docker
                install_utilities
                if [ "$ENABLE_LOGROTATE" = "true" ]; then
                    setup_logrotate
                fi
                if [ "$ENABLE_CLEANUP" = "true" ]; then
                    cleanup_system
                fi
                ;;
            13)
                # configure_ssh # Disabled - kept for compatibility
                harden_system
                create_swap
                setup_chrony
                setup_unattended_upgrades
                install_docker
                install_utilities
                install_tblocker
                block_icmp
                disable_ipv6
                if [ "$ENABLE_LOGROTATE" = "true" ]; then
                    setup_logrotate
                fi
                if [ "$ENABLE_CLEANUP" = "true" ]; then
                    cleanup_system
                fi
                ;;
            14)
                configure_dns
                ;;
            0)
                echo "Выход..."
                exit 0
                ;;
            *)
                print_error "Неверный выбор. Попробуйте снова."
                ;;
        esac

        echo ""
        read -p "Нажмите Enter для продолжения..."
    done
}

################################################################################
# Non-Interactive Mode
################################################################################

run_non_interactive() {
    print_header "Запуск в неинтерактивном режиме"
    print_info "Используются переменные окружения для автоматической настройки."

    # Always run core functions
    # configure_ssh  # Disabled - kept for compatibility
    harden_system
    create_swap
    setup_chrony
    setup_unattended_upgrades
    install_docker
    install_utilities

    # Run optional functions based on environment variables
    if [ "$INSTALL_TBLOCKER" = "true" ]; then
        install_tblocker
    fi

    if [ "$BLOCK_ICMP" = "true" ]; then
        block_icmp
    fi

    if [ "$DISABLE_IPV6" = "true" ]; then
        disable_ipv6
    fi

    if [ "$CONFIGURE_DNS" = "true" ]; then
        configure_dns
    fi

    # Run maintenance functions
    if [ "$ENABLE_LOGROTATE" = "true" ]; then
        setup_logrotate
    fi

    if [ "$ENABLE_CLEANUP" = "true" ]; then
        cleanup_system
    fi

    print_header "Настройка завершена"
    print_success "Все компоненты успешно установлены"
}

################################################################################
# Main
################################################################################

main() {
    print_header "Lightweight VPS Setup for Remnawave v$SCRIPT_VERSION"

    # Check prerequisites
    check_root
    detect_os

    # Run in appropriate mode
    if [ "$NON_INTERACTIVE" = "true" ]; then
        run_non_interactive
    else
        run_interactive
    fi
}

# Run main function
main
