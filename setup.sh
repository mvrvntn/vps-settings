#!/bin/bash

# Lightweight VPS Setup for Remnawave
# Author: Kilo Code
# Version: 1.0.0
#
# Этот скрипт выполняет базовую настройку и укрепление безопасности
# для свежеустановленного сервера Debian/Ubuntu.

# --- Цвета и стили для вывода ---
COLOR_RESET='\033[0m'
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_BLUE='\033[0;34m'
STYLE_BOLD='\033[1m'

# --- Функции для вывода сообщений ---
log_info() {
    echo -e "${COLOR_BLUE}INFO: $1${COLOR_RESET}"
}

log_success() {
    echo -e "${COLOR_GREEN}SUCCESS: $1${COLOR_RESET}"
}

log_warn() {
    echo -e "${COLOR_YELLOW}WARN: $1${COLOR_RESET}"
}

log_error() {
    echo -e "${COLOR_RED}ERROR: $1${COLOR_RESET}" >&2
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
            log_info "Обнаружена поддерживаемая ОС: $OS $VER."
        else
            log_error "Ваша ОС ($OS $VER) не поддерживается. Скрипт предназначен для Debian 11/12 и Ubuntu 20.04/22.04/24.04."
            exit 1
        fi
    else
        log_error "Не удалось определить вашу операционную систему."
        exit 1
    fi
}

# --- Основные функции настройки ---

update_system() {
    log_info "Обновление списка пакетов и системы..."
    apt-get update && apt-get upgrade -y
    log_success "Система успешно обновлена."
}

setup_ssh() {
    local port=${1:-2222}
    log_info "Настройка безопасного SSH на порту $port..."

    sed -i "s/^#?Port .*/Port $port/" /etc/ssh/sshd_config
    sed -i "s/^#?PermitRootLogin .*/PermitRootLogin yes/" /etc/ssh/sshd_config
    sed -i "s/^#?PasswordAuthentication .*/PasswordAuthentication yes/" /etc/ssh/sshd_config
    sed -i "s/^#?ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/" /etc/ssh/sshd_config
    sed -i "s/^#?MaxAuthTries .*/MaxAuthTries 3/" /etc/ssh/sshd_config
    sed -i "s/^#?MaxStartups .*/MaxStartups 10:30:60/" /etc/ssh/sshd_config

    log_warn "${STYLE_BOLD}Порт SSH будет изменен на $port!${COLOR_RESET}"
    log_warn "Не забудьте разрешить этот порт в файрволе вашего облачного провайдера, чтобы не потерять доступ."

    if systemctl restart sshd; then
        log_success "Сервис SSH перезапущен. Новый порт: $port."
    else
        log_error "Не удалось перезапустить SSH. Проверьте конфигурацию."
        exit 1
    fi
}

harden_system() {
    log_info "Укрепление безопасности и оптимизация ядра (sysctl)..."
    cat > /etc/sysctl.d/99-custom-security.conf << EOF
# Защита от IP-спуфинга
net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.all.rp_filter=1

# Включение SYN-cookie для защиты от SYN-флуда
net.ipv4.tcp_syncookies=1

# Отключение приема ICMP-редиректов
net.ipv4.conf.all.accept_redirects=0
net.ipv6.conf.all.accept_redirects=0

# Увеличение лимита отслеживаемых соединений
net.netfilter.nf_conntrack_max=2097152
EOF
    sysctl -p /etc/sysctl.d/99-custom-security.conf
    log_success "Параметры ядра применены."
}

create_swap() {
    if [ -f /swapfile ]; then
        log_info "Swap-файл /swapfile уже существует."
        return
    fi
    log_info "Создание и активация swap-файла размером 2GB..."
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    log_success "Swap-файл успешно создан и активирован."
}

install_core_utils() {
    log_info "Установка базовых утилит (htop, mc, curl, wget, git, ncdu, iptables-persistent)..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y htop mc curl wget git ncdu iptables-persistent
    log_success "Базовые утилиты установлены."
}

install_docker() {
    if command -v docker &> /dev/null; then
        log_info "Docker уже установлен."
    else
        log_info "Установка Docker..."
        apt-get install -y ca-certificates curl
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") \
          $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
          tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
        log_success "Docker успешно установлен."
    fi

    if command -v docker-compose &> /dev/null; then
        log_info "Docker Compose уже установлен."
    else
        log_info "Установка Docker Compose..."
        LATEST_COMPOSE=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker}
        mkdir -p $DOCKER_CONFIG/cli-plugins
        curl -SL https://github.com/docker/compose/releases/download/$LATEST_COMPOSE/docker-compose-linux-x86_64 -o $DOCKER_CONFIG/cli-plugins/docker-compose
        chmod +x $DOCKER_CONFIG/cli-plugins/docker-compose
        # Сделать доступным для всех пользователей
        ln -s $DOCKER_CONFIG/cli-plugins/docker-compose /usr/local/bin/docker-compose
        log_success "Docker Compose $LATEST_COMPOSE успешно установлен."
    fi
}

setup_chrony() {
    log_info "Установка и настройка chrony для синхронизации времени..."
    apt-get install -y chrony
    systemctl enable chrony
    systemctl start chrony
    log_success "Chrony установлен и запущен."
}

setup_unattended_upgrades() {
    log_info "Установка и настройка автоматических обновлений безопасности..."
    apt-get install -y unattended-upgrades
    echo 'Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Package-Blacklist {
};
Unattended-Upgrade::Automatic-Reboot "false";' > /etc/apt/apt.conf.d/50unattended-upgrades
    echo 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";' > /etc/apt/apt.conf.d/20auto-upgrades
    log_success "Автоматические обновления безопасности настроены."
}

setup_tblocker() {
    log_info "Установка и настройка tblocker..."
    curl -fsSL https://raw.githubusercontent.com/HiWay-Media/tblocker/main/install.sh | bash
    mkdir -p /opt/tblocker
    cat > /opt/tblocker/config.yaml << EOF
BlockMode: iptables
Whitelist:
  - 8.8.8.8 # Google DNS
EOF
    systemctl enable tblocker
    systemctl start tblocker
    log_success "tblocker установлен и запущен с BlockMode: iptables."
}

block_icmp() {
    log_info "Блокировка входящих ICMP-запросов (ping)..."
    iptables -A INPUT -p icmp --icmp-type echo-request -j DROP
    netfilter-persistent save
    log_success "Правило для блокировки ICMP добавлено и сохранено."
}

disable_ipv6() {
    log_info "Полное отключение IPv6..."
    cat >> /etc/sysctl.d/99-custom-disable-ipv6.conf << EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    sysctl -p /etc/sysctl.d/99-custom-disable-ipv6.conf

    sed -i 's/GRUB_CMDLINE_LINUX=""/GRUB_CMDLINE_LINUX="ipv6.disable=1"/' /etc/default/grub
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 ipv6.disable=1"/' /etc/default/grub
    update-grub
    log_success "IPv6 отключен. Требуется перезагрузка для полного применения."
}

set_timezone() {
    local tz=${1:-"Etc/UTC"}
    log_info "Установка временной зоны на $tz..."
    timedatectl set-timezone "$tz"
    log_success "Временная зона установлена: $(timedatectl | grep 'Time zone' | awk '{print $3}')"
}

# --- Интерактивное меню ---

display_menu() {
    echo -e "${STYLE_BOLD}--- Меню установки Lightweight VPS Setup ---${COLOR_RESET}"
    echo "Выберите компоненты для установки. Отметьте желаемые опции [x]."
    echo "Нажмите Enter, чтобы начать установку."
    echo ""

    options=(
        "1:🎓 Настроить безопасный SSH:Изменяет стандартный порт SSH и ужесточает параметры подключения для защиты от ботов.:on"
        "2:🎓 Укрепить и оптимизировать систему:Применяет базовые параметры безопасности ядра, создает swap и настраивает время.:on"
        "3:🎓 Установить Docker и утилиты:Устанавливает Docker, Docker Compose и основной набор утилит для администрирования.:on"
        "4:🎓 Установить tblocker:Блокирует подключения к торрент-трекерам на уровне iptables.:off"
        "5:🎓 Заблокировать ICMP (ping):Блокирует входящие ICMP-запросы для скрытия сервера от простого сканирования.:off"
        "6:🎓 Отключить IPv6:Полностью отключает протокол IPv6 на уровне ядра и загрузчика.:off"
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
        read -r -p "Ваш выбор: " choice
        echo "DEBUG: Вы ввели: '$choice'" >&2
        case $choice in
            [1-6])
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
                log_warn "Неверный ввод. Пожалуйста, выберите номер от 1 до 6 или нажмите Enter."
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
                4) INSTALL_TBLOCKER="true" ;;
                5) BLOCK_ICMP="true" ;;
                6) DISABLE_IPV6="true" ;;
            esac
        fi
    done
}

# --- Главная функция ---

main() {
    check_root
    check_os

    # Проверка на неинтерактивный режим
    if [[ -n "$SSH_PORT" || -n "$INSTALL_TBLOCKER" || -n "$BLOCK_ICMP" || -n "$DISABLE_IPV6" || -n "$TIMEZONE" ]]; then
        log_info "Обнаружены переменные окружения. Запуск в неинтерактивном режиме."

        update_system
        install_core_utils
        
        # Обязательные компоненты
        setup_ssh "${SSH_PORT:-2222}"
        harden_system
        create_swap
        setup_chrony
        setup_unattended_upgrades
        install_docker
        
        # Опциональные компоненты
        [ -n "$TIMEZONE" ] && set_timezone "$TIMEZONE"
        [ "$INSTALL_TBLOCKER" == "true" ] && setup_tblocker
        [ "$BLOCK_ICMP" == "true" ] && block_icmp
        [ "$DISABLE_IPV6" == "true" ] && disable_ipv6

    else
        # Интерактивный режим
        clear
        display_menu
        
        log_info "Начало установки на основе вашего выбора..."
        
        update_system
        install_core_utils

        if [ "$INTERACTIVE_SSH" == "true" ]; then
            read -r -p "Введите новый порт для SSH (по умолчанию 2222): " user_port
            setup_ssh "${user_port:-2222}"
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

        [ "$INSTALL_TBLOCKER" == "true" ] && setup_tblocker
        [ "$BLOCK_ICMP" == "true" ] && block_icmp
        [ "$DISABLE_IPV6" == "true" ] && disable_ipv6
    fi

    log_success "${STYLE_BOLD}Настройка сервера завершена!${COLOR_RESET}"
    log_warn "Рекомендуется перезагрузить сервер для применения всех изменений (особенно отключения IPv6)."
}

main "$@"