#!/bin/bash
check_permissions() {
    if [[ "$EUID" -ne 0 ]]; then
        echo "Skrypt musi być uruchomiony z uprawnieniami roota."
        exit 1
    fi
}

check_permissions

check_for_updates() {
    local current_version="0.1.0" 
    local latest_version=$(curl -sS "https://api.github.com/repos/keyhostgg/auto-install-script-bot-discord/releases/latest" | grep -o '"tag_name": ".*"' | cut -d'"' -f4)

    if [ -z "$latest_version" ]; then
        echo "Nie udało się sprawdzić dostępności aktualizacji."
    elif [ "$current_version" == "$latest_version" ]; then
        echo "Posiadasz najnowszą wersję skryptu ($current_version)."
    else
        echo "Dostępna jest nowa wersja skryptu ($latest_version). Możesz ją pobrać ze strony projektu."
    fi
}

check_for_updates

check_if_already_running() {
    local lock_file="/tmp/script.lock"

    if [ -f "$lock_file" ]; then
        echo "Skrypt jest już uruchomiony."
        exit 1
    else
        touch "$lock_file"
        trap 'rm -f "$lock_file"; exit $?' INT TERM EXIT
    fi
}

check_if_already_running

show_spinner() {
    local pid=$1
    local delay=0.1
    local spinner=( '|' '/' '-' '\' )

    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        for i in "${spinner[@]}"; do
            echo -ne "\r$i"
            sleep $delay
        done
    done
    echo -ne "\r"
}

install_nodejs() {
    echo "Pobieranie i instalacja Node.js..."

    if ! apt install -y -qq ca-certificates curl gnupg > /dev/null 2>&1; then
        echo "Błąd podczas instalacji wymaganych pakietów."
        return 1
    fi

    mkdir -p /etc/apt/keyrings

    if ! curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --batch --yes --dearmor -o /etc/apt/keyrings/nodesource.gpg; then
        echo "Błąd podczas pobierania klucza GPG."
        return 1
    fi

    local NODE_MAJOR
    local opcja

    echo "Wybierz wersję Node.js do zainstalowania:"
    echo "1) Node.js 20"
    echo "2) Node.js 18"
    echo "3) Node.js 16"
    read -p "Wybierz opcję (1, 2, 3): " opcja

    case $opcja in
        1) NODE_MAJOR=20 ;;
        2) NODE_MAJOR=18 ;;
        3) NODE_MAJOR=16 ;;
        *) echo "Niepoprawna opcja. Anulowanie." ; return 1 ;;
    esac

    echo "Dodawanie repozytorium Node.js..."
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list > /dev/null

    echo "Aktualizacja listy pakietów..."
    apt update -qq > /dev/null 2>&1 &
    local pid=$!
    show_spinner $pid
    wait $pid
    if [ $? -ne 0 ]; then
        echo "Błąd podczas aktualizacji listy pakietów."
        return 1
    fi

    echo "Instalacja Node.js..."
    apt install -y -qq nodejs > /dev/null 2>&1 &
    pid=$!
    show_spinner $pid
    wait $pid
    if [ $? -ne 0 ]; then
        echo "Błąd podczas instalacji Node.js."
        return 1
    fi

    echo "Instalacja pm2..."
    npm install -g pm2 > /dev/null 2>&1 &
    pid=$!
    show_spinner $pid
    wait $pid
    if [ $? -ne 0 ]; then
        echo "Błąd podczas instalacji pm2."
        return 1
    fi

    echo "Node.js i pm2 zostały pomyślnie zainstalowane."
}

error_message() {
    echo "Błąd: $1" >&2
}


run_bot() {
    echo "Przygotowanie do uruchomienia bota..."
    sleep 3
    tput cuu1 && tput el
    echo "Uruchamianie bota..."

    echo "1) Wyszukaj plik"
    echo "2) Wprowadź ścieżkę pliku"
    read -p "Wybierz opcję (1 lub 2): " option

    case "$option" in
        1)
            search_dirs=("/home" "/" "/root")
            found_files=()
            for dir in "${search_dirs[@]}"; do
                if [ -d "$dir" ]; then
                    while IFS= read -r file; do
                        found_files+=("$file")
                    done < <(find "$dir" -maxdepth 3 -type f -name "*.js")
                else
                    error_message "Katalog '$dir' nie istnieje lub nie masz do niego dostępu."
                fi
            done

            if [ ${#found_files[@]} -eq 0 ]; then
                error_message "Nie znaleziono plików JavaScript."
                return 1
            fi

            echo "Znaleziono pliki JavaScript:"
            for ((i=0; i<${#found_files[@]}; i++)); do
                echo "$(($i+1))) ${found_files[$i]}"
            done

            read -p "Wybierz numer pliku do uruchomienia lub wpisz 'q' aby wyjść: " file_number

            [[ "$file_number" == 'q' ]] && return 0
            if ! [[ "$file_number" =~ ^[0-9]+$ ]] || ((file_number < 1)) || ((file_number > ${#found_files[@]})); then
                error_message "Niepoprawny numer pliku."
                return 1
            fi

            selected_file=${found_files[$(($file_number-1))]}
            ;;
        2)
            read -p "Wprowadź ścieżkę do pliku JavaScript: " selected_file
            if [ ! -f "$selected_file" ]; then
                error_message "Plik nie istnieje."
                return 1
            fi
            ;;
        *)
            error_message "Niepoprawny wybór opcji."
            return 1
            ;;
    esac

    echo "Uruchamianie pliku: $selected_file"
    if ! command -v node &> /dev/null; then
        error_message "Node.js nie jest zainstalowany."
        return 1
    fi

    pm2 start "$selected_file"
}

restart_bot() {
    echo "Restartowanie bota..."
    if ! command -v node &> /dev/null; then
        error_message "Node.js nie jest zainstalowany."
        return 1
    fi

    pm2 restart "$selected_file"
}

monitor_bot() {
    echo "Monitorowanie bota..."
    pm2 monit
}

install_python() {
    log "Pobieranie i instalacja Pythona..."
    apt-get install -y python3 python3-pip > /dev/null 2>&1 &
    pid=$!
    show_spinner $pid
    wait $pid
    if [ $? -ne 0 ]; then
        error_message "Błąd podczas instalacji Pythona."
        return 1
    fi
    log "Python zainstalowany pomyślnie."
}

install_java() {
    log "Pobieranie i instalacja Javy..."
    apt-get install -y default-jdk > /dev/null 2>&1 &
    pid=$!
    show_spinner $pid
    wait $pid
    if [ $? -ne 0 ]; then
        error_message "Błąd podczas instalacji Javy."
        return 1
    fi
    log "Java zainstalowana pomyślnie."
}

nodejs_options_menu() {
    while true; do
        echo -e "\e[1;30m===================================\e[0m"
        echo -e "\e[1;31m      Opcje Node.js\e[0m"
        echo -e "\e[1;30m===================================\e[0m"
        echo -e "\e[1;33m1. \e[0mUruchom bota"
        echo -e "\e[1;33m2. \e[0mZrestartuj bota"
        echo -e "\e[1;33m3. \e[0mMonitoruj bota"
        echo -e "\e[1;33m4. \e[0mZainstaluj Node.js"
        echo -e "\e[1;33m5. \e[0mPowrót do menu głównego"
        echo -e "\e[1;30m===================================\e[0m"
        read -p "Wpisz numer opcji: " nodejs_option

        case $nodejs_option in
            1)
                run_bot
                ;;
            2)
                restart_bot
                ;;
            3)
                monitor_bot
                ;;
            4)
                install_nodejs
                ;;
            5)
                return
                ;;
            *)
                echo -e "\e[1;31mNiepoprawny wybór. Wpisz numer odpowiadający opcji.\e[0m"
                ;;
        esac
    done
}

display_menu() {
    clear
    echo -e "\e[1;30m===================================\e[0m"
    echo -e "\e[1;31m      Wybierz opcję instalacji lub uzyskaj pomoc\e[0m"
    echo -e "\e[1;30m===================================\e[0m"
    echo -e "\e[1;33m1. \e[0mOpcje Node.js"
    echo -e "\e[1;33m2. \e[0mInstalacja Pythona"
    echo -e "\e[1;33m3. \e[0mInstalacja Javy"
    echo -e "\e[1;33m5. \e[0mPomoc"
    echo -e "\e[1;33m6. \e[0mWyjście"
    echo -e "\e[1;30m===================================\e[0m"
}

while true; do
    display_menu
    read -p "Wpisz numer opcji: " option

    case $option in
        1)
            nodejs_options_menu
            ;;
        2)
            install_python
            ;;
        3)
            install_java
            ;;
        5)
            show_help
            ;;
        6)
            echo "Wybrano opcję wyjścia."
            exit 0
            ;;
        *)
            echo -e "\e[1;31mNiepoprawny wybór. Wpisz numer odpowiadający opcji.\e[0m"
            ;;
    esac
done
