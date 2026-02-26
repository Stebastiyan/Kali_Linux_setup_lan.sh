#!/bin/bash

# Скрипт для настройки прямого Ethernet-соединения между двумя компьютерами
# и опциональной раздачи интернета через Wi-Fi (NAT)
# Запускать с правами root!

set -e  # Прерывать выполнение при ошибке

# Функция для вывода сообщений с цветом
info() { echo -e "\e[32m[INFO]\e[0m $1"; }
error() { echo -e "\e[31m[ERROR]\e[0m $1" >&2; }

# Проверка root
if [[ $EUID -ne 0 ]]; then
    error "Скрипт должен запускаться от root (sudo)."
    exit 1
fi

# Получаем список сетевых интерфейсов (кроме loopback)
interfaces=($(ip -o link show | awk -F': ' '{print $2}' | grep -v lo))
if [[ ${#interfaces[@]} -eq 0 ]]; then
    error "Не найдено ни одного сетевого интерфейса."
    exit 1
fi

info "Доступные интерфейсы: ${interfaces[*]}"

# Запрос номера компьютера
read -p "Введите номер компьютера (1 или 2): " pc_num
if [[ "$pc_num" != "1" && "$pc_num" != "2" ]]; then
    error "Номер должен быть 1 или 2."
    exit 1
fi

# Выбор Ethernet-интерфейса для прямого соединения
echo "Доступные интерфейсы:"
select iface in "${interfaces[@]}"; do
    if [[ -n "$iface" ]]; then
        break
    else
        echo "Неверный выбор. Попробуйте снова."
    fi
done

# Проверяем, не назначен ли уже IP на этот интерфейс, и предлагаем сбросить
current_ips=$(ip -4 addr show "$iface" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | tr '\n' ' ')
if [[ -n "$current_ips" ]]; then
    echo "На интерфейсе $iface уже есть IP-адреса: $current_ips"
    read -p "Очистить все IP на интерфейсе перед настройкой? (y/n): " clean
    if [[ "$clean" == "y" || "$clean" == "Y" ]]; then
        ip addr flush dev "$iface"
        info "IP-адреса на $iface сброшены."
    fi
fi

# Назначаем статический IP в зависимости от номера
if [[ "$pc_num" == "1" ]]; then
    ip_addr="192.168.1.1/24"
else
    ip_addr="192.168.1.2/24"
fi

info "Назначаем IP $ip_addr на интерфейс $iface..."
ip addr add "$ip_addr" dev "$iface"
ip link set "$iface" up
info "Интерфейс $iface поднят."

# Проверка связи (ping) с соседом (если он уже настроен)
if [[ "$pc_num" == "1" ]]; then
    peer_ip="192.168.1.2"
else
    peer_ip="192.168.1.1"
fi

info "Проверка связи с $peer_ip (ожидание 3 секунд)..."
if ping -c 1 -W 3 "$peer_ip" &> /dev/null; then
    info "Связь с соседом установлена!"
else
    info "Связь с соседом не установлена. Возможно, второй компьютер ещё не настроен."
fi

# Если это компьютер 1, спрашиваем про раздачу интернета (NAT)
if [[ "$pc_num" == "1" ]]; then
    echo ""
    read -p "Настроить раздачу интернета с другого интерфейса (например, Wi-Fi) на компьютер 2? (y/n): " nat_choice
    if [[ "$nat_choice" == "y" || "$nat_choice" == "Y" ]]; then
        # Показываем список интерфейсов для выбора источника интернета
        echo "Выберите интерфейс, через который компьютер выходит в интернет (например, wlan0, usb0):"
        select ext_iface in "${interfaces[@]}"; do
            if [[ -n "$ext_iface" && "$ext_iface" != "$iface" ]]; then
                break
            else
                echo "Неверный выбор или выбран тот же интерфейс. Выберите другой."
            fi
        done

        # Включаем IP forwarding
        sysctl -w net.ipv4.ip_forward=1
        # Делаем постоянным (опционально)
        if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
            echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
            info "IP forwarding добавлен в /etc/sysctl.conf"
        fi

        # Настраиваем iptables (NAT)
        iptables -t nat -A POSTROUTING -o "$ext_iface" -j MASQUERADE
        iptables -A FORWARD -i "$ext_iface" -o "$iface" -m state --state RELATED,ESTABLISHED -j ACCEPT
        iptables -A FORWARD -i "$iface" -o "$ext_iface" -j ACCEPT

        info "Правила iptables добавлены."

        # Сохраняем правила (если установлен iptables-persistent)
        if command -v netfilter-persistent save &> /dev/null; then
            netfilter-persistent save
            info "Правила iptables сохранены."
        else
            info "Для сохранения правил после перезагрузки установите iptables-persistent."
        fi

        info "Раздача интернета настроена. Компьютер 2 теперь может использовать шлюз 192.168.1.1."
    fi
fi

# Если это компьютер 2, предлагаем прописать DNS (для доступа в интернет через компьютер 1)
if [[ "$pc_num" == "2" ]]; then
    echo ""
    read -p "Прописать DNS-сервер (8.8.8.8) для выхода в интернет через компьютер 1? (y/n): " dns_choice
    if [[ "$dns_choice" == "y" || "$dns_choice" == "Y" ]]; then
        # Проверяем, не используется ли resolvconf
        if command -v resolvconf &> /dev/null; then
            echo "nameserver 8.8.8.8" | resolvconf -a eth0.inet
            info "DNS добавлен через resolvconf."
        else
            # Прямая запись в /etc/resolv.conf
            if ! grep -q "^nameserver 8.8.8.8" /etc/resolv.conf; then
                echo "nameserver 8.8.8.8" >> /etc/resolv.conf
                info "DNS 8.8.8.8 добавлен в /etc/resolv.conf"
            else
                info "DNS 8.8.8.8 уже присутствует."
            fi
        fi
    fi
fi

# Опционально: записать настройки в /etc/network/interfaces для постоянства
echo ""
read -p "Сохранить настройки в /etc/network/interfaces для постоянного использования? (y/n): " save_perm
if [[ "$save_perm" == "y" || "$save_perm" == "Y" ]]; then
    # Делаем бэкап
    cp /etc/network/interfaces /etc/network/interfaces.bak
    info "Создан бэкап /etc/network/interfaces.bak"

    # Добавляем конфигурацию для интерфейса, если её ещё нет
    if ! grep -q "^iface $iface inet static" /etc/network/interfaces; then
        cat >> /etc/network/interfaces <<EOF

auto $iface
iface $iface inet static
    address ${ip_addr%/*}
    netmask 255.255.255.0
EOF
        info "Конфигурация для $iface добавлена в /etc/network/interfaces."
    else
        info "Конфигурация для $iface уже существует в /etc/network/interfaces."
    fi
fi

info "Настройка завершена."
