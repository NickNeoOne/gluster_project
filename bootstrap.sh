#!/bin/bash

# Copyright (c) 2026 NickNeoOne
# SPDX-License-Identifier: MIT

# --- ЦВЕТОВАЯ ПАЛИТРА ---
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- ИНИЦИАЛИЗАЦИЯ ---
MODE="none"
# Извлекаем remote_user и список хостов из конфигов Ansible
USER_NAME=$(grep '^remote_user' ansible.cfg | awk -F'=' '{print $2}' | tr -d '[:space:]')
NODES=$(grep 'ansible_host=' hosts.ini | grep -v '^#' | awk -F'ansible_host=' '{print $2}' | awk '{print $1}')
SSH_KEY="$HOME/.ssh/id_ed25519"

SUCCESS_COUNT=0
FAILED_COUNT=0
SKIPPED_COUNT=0

# --- ФУНКЦИЯ СПРАВКИ ---
show_help() {
    echo -e "Использование: $0 [${YELLOW}ПАРАМЕТР${NC}]"
    echo ""
    echo "Параметры:"
    echo -e "  ${YELLOW}-k${NC}    Только копирование SSH-ключей."
    echo -e "  ${YELLOW}-s${NC}    Копирование SSH-ключей + права sudo (с запросом пароля)."
    echo -e "        При запуске Ansible вам необходимо использовать (ключ ${RED}-K${NC}) и вводить пароль для sudo."
    echo -e "  ${YELLOW}-f${NC}    Копирование SSH-ключей + права sudo ${RED}NOPASSWD${NC} (без пароля)."
    echo -e "  ${YELLOW}-h${NC}    Показать эту справку."
    echo ""
    exit 0
}

# Обработка аргументов
while getopts "ksfh" opt; do
  case $opt in
    k) MODE="ssh_only"; MODE_DESC="${YELLOW}Только копирование SSH-ключей${NC}" ;;
    s) MODE="sudo_pass"; MODE_DESC="${YELLOW}Настройка SSH + права sudo (через su, с паролем)${NC}" ;;
    f) MODE="sudo_nopass"; MODE_DESC="${RED}Настройка SSH + права sudo NOPASSWD (через su, без пароля)${NC}" ;;
    h|*) show_help ;;
  esac
done

if [ "$MODE" == "none" ]; then show_help; fi

# --- ИНФОРМАЦИОННЫЙ БЛОК ---
clear
echo "================================================================"
echo "              ПОДГОТОВКА СЕРВЕРОВ К ДЕПЛОЮ                      "
echo "================================================================"
echo -e " Пользователь: ${YELLOW}$USER_NAME${NC}"
echo -e " Режим: $MODE_DESC"
echo -e " Ключ: ${YELLOW}$SSH_KEY${NC}"
echo "----------------------------------------------------------------"
echo " Список узлов для обработки:"
for NODE in $NODES; do echo -e "  - ${YELLOW}$NODE${NC}"; done
echo "----------------------------------------------------------------"
read -p " Вы подтверждаете запуск? (y/n): " main_confirm
[[ "$main_confirm" != [yY] ]] && exit 0

# 1. Проверка/Генерация ключа
if [ ! -f "$SSH_KEY" ]; then
    echo -e "\n[*] Генерация ключа Ed25519..."
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N ""
fi

# 2. Основной цикл по узлам
for NODE in $NODES; do
    echo -e "\n>>> Узел: ${YELLOW}$NODE${NC}"

    # Пинг
    if ! ping -c 1 -W 2 "$NODE" > /dev/null 2>&1; then
        echo -e "    ${RED}[!] OFFLINE: Узел не отвечает. Пропуск.${NC}"
        ((SKIPPED_COUNT++))
        continue
    fi

    # Очистка known_hosts
    if ssh-keygen -F "$NODE" > /dev/null 2>&1; then
        read -p "    [?] Удалить старый SSH-отпечаток $NODE? (y/n): " confirm
        [[ "$confirm" == [yY] ]] && ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$NODE" > /dev/null 2>&1
    fi

    # Копирование ключа (базовый этап)
    if ! ssh-copy-id -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$SSH_KEY.pub" "$USER_NAME@$NODE"; then
        echo -e "    ${RED}[X] ОШИБКА: Не удалось скопировать ключ на $NODE.${NC}"
        ((FAILED_COUNT++))
        continue
    fi
    
    # Повышение прав через su -
    case $MODE in
        "sudo_pass")
            echo "    [*] Настройка sudo (с паролем). Введите пароль ROOT:"
            ssh -t "$USER_NAME@$NODE" "su -c \"echo '$USER_NAME ALL=(ALL) ALL' > /etc/sudoers.d/$USER_NAME && chmod 0440 /etc/sudoers.d/$USER_NAME\""
            ;;
        "sudo_nopass")
            echo "    [*] Настройка sudo NOPASSWD. Введите пароль ROOT:"
            ssh -t "$USER_NAME@$NODE" "su -c \"echo '$USER_NAME ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$USER_NAME && chmod 0440 /etc/sudoers.d/$USER_NAME\""
            ;;
        "ssh_only") (exit 0) ;;
    esac

    # Проверка успеха последней операции
    if [ $? -eq 0 ]; then
        echo -e "    ${GREEN}[✓] Узел $NODE успешно настроен.${NC}"
        ((SUCCESS_COUNT++))
    else
        echo -e "    ${RED}[X] ОШИБКА: Сбой при выполнении команд на $NODE.${NC}"
        ((FAILED_COUNT++))
    fi
done

# --- ФИНАЛЬНЫЙ ОТЧЕТ ---
echo -e "\n================================================================"
echo " ИТОГИ ПОДГОТОВКИ:"
echo -e "   Успешно настроено:  ${GREEN}$SUCCESS_COUNT${NC}"
echo -e "   Ошибок (Failed):    ${RED}$FAILED_COUNT${NC}"
echo -e "   Пропущено (Offline): ${YELLOW}$SKIPPED_COUNT${NC}"
echo "================================================================"

if [ $FAILED_COUNT -eq 0 ] && [ $SKIPPED_COUNT -eq 0 ]; then
    echo -e " ${GREEN}[✓] СТАТУС: ИДЕАЛЬНО. Все узлы готовы к работе.${NC}\n"
    exit 0
elif [ $SUCCESS_COUNT -gt 0 ]; then
    echo -e " ${YELLOW}[!] СТАТУС: ЧАСТИЧНЫЙ УСПЕХ. Проверьте проблемные узлы.${NC}\n"
    exit 1
else
    echo -e " ${RED}[X] СТАТУС: КРИТИЧЕСКАЯ ОШИБКА. Ни один узел не настроен.${NC}\n"
    exit 1
fi
