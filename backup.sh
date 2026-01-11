#!/bin/bash

# Ustawienie ścieżki do pliku konfiguracyjnego
CONFIG_FILE="$(dirname "$0")/backup.conf"

# Sprawdzenie czy plik konfiguracyjny istnieje
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Błąd: Brak pliku konfiguracyjnego $CONFIG_FILE"
    exit 1
fi

# Wczytanie konfiguracji
source "$CONFIG_FILE"

# Utworzenie katalogu logów jeśli nie istnieje
mkdir -p "$LOG_DIR"

# Ustalenie nazwy pliku logu (np. 2025-week-20.log)
CURRENT_WEEK=$(date +%Y-week-%V)
LOG_FILE="$LOG_DIR/${CURRENT_WEEK}.log"

# Funkcja logowania
log() {
    local TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$TIMESTAMP $1" | tee -a "$LOG_FILE"
}

# Blokada przed równoległym uruchomieniem (Lock file)
LOCK_FILE="/tmp/backup_script.lock"
if [ -e "$LOCK_FILE" ]; then
    log "Zaniechanie działania: Skrypt już działa (plik blokady $LOCK_FILE istnieje)."
    exit 1
fi

# Utworzenie blokady
touch "$LOCK_FILE"
# Zapewnienie usunięcia blokady przy wyjściu (nawet w przypadku błędu)
trap "rm -f '$LOCK_FILE'" EXIT

log "Rozpoczęcie działania skryptu kopii zapasowej."

# Sprawdzenie dostępności katalogów lokalnych
if [ ! -d "$LOCAL_BACKUP_DIR" ]; then
    log "Tworzenie lokalnego katalogu kopii: $LOCAL_BACKUP_DIR"
    mkdir -p "$LOCAL_BACKUP_DIR"
fi

if [ ! -d "$TEMP_DIR" ]; then
    log "Tworzenie katalogu tymczasowego: $TEMP_DIR"
    mkdir -p "$TEMP_DIR"
fi

# Sprawdzenie dostępności hosta zdalnego
log "Sprawdzanie dostępności hosta zdalnego: $REMOTE_HOST"
ping -c 1 -W 2 "${REMOTE_HOST#*@}" > /dev/null 2>&1
if [ $? -ne 0 ]; then
    log "Ostrzeżenie: Host zdalny nie odpowiada na ping. Próba połączenia SSH..."
fi

ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$REMOTE_HOST" "exit" > /dev/null 2>&1
if [ $? -ne 0 ]; then
    log "Błąd krytyczny: Nie można połączyć się z hostem zdalnym $REMOTE_HOST przez SSH. Przerywanie działania."
    exit 1
fi
REMOTE_AVAILABLE=true

# Sprawdzenie miejsca na dysku
log "Szacowanie wymaganego miejsca na dysku..."
REQUIRED_SPACE=0
for SRC in "${SOURCE_DIRS[@]}"; do
    if [ -e "$SRC" ]; then
        # du -s zwraca rozmiar w kilobajtach (domyślnie)
        SIZE=$(du -s "$SRC" | awk '{print $1}')
        REQUIRED_SPACE=$((REQUIRED_SPACE + SIZE))
    fi
done

# Sprawdzenie dostępnego miejsca (df zwraca w 1K blokach w kolumnie 4)
AVAILABLE_SPACE=$(df "$LOCAL_BACKUP_DIR" | awk 'NR==2 {print $4}')

log "Wymagane miejsce: ${REQUIRED_SPACE}k, Dostępne miejsce: ${AVAILABLE_SPACE}k"

if [ "$REQUIRED_SPACE" -gt "$AVAILABLE_SPACE" ]; then
    log "Błąd krytyczny: Brak wystarczającego miejsca na dysku. Wymagane: ${REQUIRED_SPACE}k, Dostępne: ${AVAILABLE_SPACE}k. Przerywanie."
    exit 1
fi

# Ustalenie bieżącego okresu
if [ "$BACKUP_PERIOD" == "months" ]; then
    PERIOD_TAG="miesiac_$(date +%Y-%m)"
elif [ "$BACKUP_PERIOD" == "weeks" ]; then
    PERIOD_TAG="tydzien_$(date +%Y-week-%V)"
else
    PERIOD_TAG="dzien_$(date +%Y-%m-%d)"
fi

CURRENT_TARGET_DIR="$LOCAL_BACKUP_DIR/$PERIOD_TAG"
REPO_DIR="$CURRENT_TARGET_DIR/repozytoria"
FILES_DIR="$CURRENT_TARGET_DIR/zasoby_archiwalne"

# Tworzenie struktury katalogów dla bieżącego okresu
mkdir -p "$REPO_DIR"
mkdir -p "$FILES_DIR"

# Przetwarzanie źródeł
for SRC in "${SOURCE_DIRS[@]}"; do
    if [ ! -e "$SRC" ]; then
        log "Ostrzeżenie: Źródło $SRC nie istnieje. Pomijanie."
        continue
    fi

    BASENAME=$(basename "$SRC")
    # Zabezpieczenie spacji - rsync i git radzą sobie z cytowanymi ścieżkami,
    # ale dla pewności logujemy nazwę.
    
    # Sprawdzenie czy to repozytorium git
    if [ -d "$SRC/.git" ]; then
        DEST_REPO="$REPO_DIR/$BASENAME.git"
        if [ -d "$DEST_REPO" ]; then
            log "Aktualizacja repozytorium $BASENAME..."
            git -C "$DEST_REPO" fetch --all >> "$LOG_FILE" 2>&1
        else
            log "Klonowanie repozytorium $BASENAME..."
            git clone --mirror "$SRC" "$DEST_REPO" >> "$LOG_FILE" 2>&1
        fi
    else
        # Zwykły katalog - rsync
        log "Synchronizacja katalogu $SRC..."
        RSYNC_OPTS="-av --delete"
        
        # Wyłączenie plików specjalnych jeśli skonfigurowano
        if [ "$IGNORE_SPECIAL_FILES" = true ]; then
            RSYNC_OPTS="$RSYNC_OPTS --no-specials --no-devices"
        fi
        
        # Rsync do katalogu zasobów
        # Używamy relative pathing lub po prostu kopiujemy do podkatalogu o tej samej nazwie
        rsync $RSYNC_OPTS "$SRC" "$FILES_DIR/" >> "$LOG_FILE" 2>&1
    fi
done

# Archiwizacja i wysyłanie starych okresów
log "Sprawdzanie zakończonych okresów do archiwizacji..."

for DIR in "$LOCAL_BACKUP_DIR"/*; do
    [ -d "$DIR" ] || continue
    DIR_NAME=$(basename "$DIR")
    
    # Jeśli katalog nie jest bieżącym okresem i pasuje do wzorca okresów (miesiac_, tydzien_, dzien_)
    if [ "$DIR_NAME" != "$PERIOD_TAG" ] && [[ "$DIR_NAME" =~ ^(miesiac|tydzien|dzien)_ ]]; then
        log "Znaleziono zakończony okres: $DIR_NAME. Rozpoczynanie archiwizacji."
        
        ARCHIVE_NAME="${DIR_NAME}.tar.gz"
        TEMP_ARCHIVE_PATH="$TEMP_DIR/$ARCHIVE_NAME"
        
        # Kompresja
        log "Kompresja $DIR_NAME do $TEMP_ARCHIVE_PATH..."
        tar -czf "$TEMP_ARCHIVE_PATH" -C "$LOCAL_BACKUP_DIR" "$DIR_NAME" >> "$LOG_FILE" 2>&1
        
        if [ $? -eq 0 ]; then
            log "Kompresja zakończona sukcesem."
            
            if [ "$REMOTE_AVAILABLE" = true ]; then
                log "Wysyłanie $ARCHIVE_NAME na $REMOTE_HOST..."
                
                # Upewnienie się, że zdalny katalog archiwum istnieje
                ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$REMOTE_HOST" "mkdir -p $REMOTE_DEST_DIR/archiwum" >> "$LOG_FILE" 2>&1
                
                # Przesłanie pliku
                scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$TEMP_ARCHIVE_PATH" "$REMOTE_HOST:$REMOTE_DEST_DIR/archiwum/" >> "$LOG_FILE" 2>&1
                
                if [ $? -eq 0 ]; then
                    log "Wysłano pomyślnie. Usuwanie lokalnej kopii i archiwum tymczasowego."
                    rm -rf "$DIR"
                    rm -f "$TEMP_ARCHIVE_PATH"
                else
                    log "Błąd: Nie udało się wysłać archiwum na host zdalny. Pozostawiam kopię lokalną."
                fi
            else
                log "Host zdalny niedostępny. Archiwum pozostaje w $TEMP_DIR (lub katalog źródłowy pozostaje nienaruszony)."
                # Możemy usunąć tymczasowe archiwum, skoro nie wysłaliśmy, aby nie zajmować miejsca,
                # i spróbować ponownie przy następnym uruchomieniu (bo katalog źródłowy nadal tam jest).
                rm -f "$TEMP_ARCHIVE_PATH"
            fi
        else
            log "Błąd kompresji katalogu $DIR_NAME."
        fi
    fi
done

log "Zakończenie skryptu."
