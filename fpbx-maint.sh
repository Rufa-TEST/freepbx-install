#!/bin/bash
#
# fpbx-maint.sh — безопасное обслуживание уже работающего FreePBX 17 (Debian 12).
#
# Только то, что проверено на боевых серверах. Ничего не делает без ключа,
# не перезапускает Asterisk, по умолчанию отказывается работать при живых звонках.
#
# Использование:
#   ./fpbx-maint.sh --status        # версии, активные звонки, место под записи
#   ./fpbx-maint.sh --update        # бэкап + обновление модулей FreePBX + chown + reload
#   ./fpbx-maint.sh --php           # security-обновление php8.2* + рестарт Apache при (deleted) libphp
#   ./fpbx-maint.sh --update --php  # оба шага
#   ./fpbx-maint.sh --force ...     # не останавливаться из-за активных звонков
#
# Идемпотентно: повторный запуск ничего не ломает.
# Asterisk не перезапускается никогда. Apache рестартуется только в --php и только
# если процесс держит удалённую libphp (перезапуск Apache звонки не затрагивает).
#
set -uo pipefail

LOG="/var/log/fpbx-maint-$(date +%Y%m%d-%H%M%S).log"
BACKUP_DIR="/root/fpbx-pre-update-$(date +%F-%H%M)"
REC_DIR="/var/spool/asterisk/monitor"

DO_STATUS=0; DO_UPDATE=0; DO_PHP=0; FORCE=0

say()  { echo -e "\n=== $* ===" | tee -a "$LOG"; }
note() { echo "  $*" | tee -a "$LOG"; }
die()  { echo "ОШИБКА: $*" | tee -a "$LOG"; exit 1; }
usage() { sed -n '2,17p' "$0"; exit 1; }

for a in "$@"; do
  case "$a" in
    --status) DO_STATUS=1 ;;
    --update) DO_UPDATE=1 ;;
    --php)    DO_PHP=1 ;;
    --force)  FORCE=1 ;;
    *) usage ;;
  esac
done
[ $((DO_STATUS + DO_UPDATE + DO_PHP)) -eq 0 ] && usage
[ "$(id -u)" -eq 0 ] || die "нужен root"
command -v fwconsole >/dev/null 2>&1 || die "fwconsole не найден — FreePBX не установлен"

# Число активных звонков. Пусто/ошибка = неизвестно (считаем как 0, но говорим об этом).
active_calls() {
  asterisk -rx 'core show channels count' 2>/dev/null | awk '/active call/ {print $1; exit}'
}

guard_calls() {
  local n
  n=$(active_calls)
  if [ -z "$n" ]; then
    note "активные звонки: не удалось определить (Asterisk не отвечает?)"
    return 0
  fi
  note "активных звонков: $n"
  if [ "$n" -gt 0 ] && [ $FORCE -eq 0 ]; then
    die "идут звонки. Повторите позже или добавьте --force"
  fi
}

# ---------------------------------------------------------------------------
status() {
  say "Состояние"
  note "Debian:   $(. /etc/os-release; echo "$PRETTY_NAME")"
  note "Asterisk: $(asterisk -V 2>/dev/null || echo нет)"
  note "FreePBX:  $(fwconsole --version 2>/dev/null | head -1)"
  note "PHP:      $(php -v 2>/dev/null | head -1 | awk '{print $2}')"
  note "активных звонков: $(active_calls)"
  if [ -d "$REC_DIR" ]; then
    note "записи: $(du -sh "$REC_DIR" 2>/dev/null | awk '{print $1}'), свободно на разделе: $(df -h "$REC_DIR" | awk 'NR==2{print $4}')"
    note "пустых файлов записи (<=100 байт): $(find "$REC_DIR" -type f -size -101c 2>/dev/null | wc -l)"
  fi
  local pid
  pid=$(pgrep -o apache2 2>/dev/null || true)
  if [ -n "$pid" ] && grep -q 'libphp8.2.so (deleted)' "/proc/$pid/maps" 2>/dev/null; then
    note "Apache держит удалённую libphp — нужен рестарт (--php сделает это)"
  fi
  note "обновления модулей: $(fwconsole ma showupgrades 2>/dev/null | grep -ci 'upgrade' || true) строк в showupgrades"
}

# ---------------------------------------------------------------------------
update_modules() {
  say "Обновление модулей FreePBX"
  guard_calls

  mkdir -p "$BACKUP_DIR"
  cp -a /etc/asterisk "$BACKUP_DIR/etc-asterisk" 2>>"$LOG"
  mysqldump --single-transaction asterisk > "$BACKUP_DIR/asterisk.sql" 2>>"$LOG" \
    && note "бэкап БД: $BACKUP_DIR/asterisk.sql" \
    || note "ВНИМАНИЕ: дамп БД не снят, см. $LOG"

  fwconsole ma upgradeall 2>&1 | tee -a "$LOG" | tail -15
  fwconsole chown >>"$LOG" 2>&1
  fwconsole reload 2>&1 | tail -5 | tee -a "$LOG"
  note "FreePBX: $(fwconsole --version 2>/dev/null | head -1)"
  note "restart не делаем: Asterisk остаётся в работе"
}

# ---------------------------------------------------------------------------
# Только пакеты php8.2* и только из уже подключённых репозиториев Debian.
# После обновления mod_php Apache держит старую libphp8.2.so (deleted) —
# GUI работает на старой версии PHP до рестарта Apache.
update_php() {
  say "Security-обновление PHP 8.2"
  guard_calls

  local pkgs
  pkgs=$(dpkg-query -W -f='${Package} ${Status}\n' 'php8.2*' 'libapache2-mod-php8.2' 2>/dev/null \
         | awk '$NF=="installed"{print $1}' | sort -u)
  [ -n "$pkgs" ] || die "пакеты php8.2* не найдены"

  note "было: $(php -v 2>/dev/null | head -1 | awk '{print $2}')"
  apt-get update >>"$LOG" 2>&1 || die "apt-get update не отработал, см. $LOG"
  # shellcheck disable=SC2086
  DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade $pkgs >>"$LOG" 2>&1 \
    || die "обновление php8.2* не прошло, см. $LOG"
  note "стало: $(php -v 2>/dev/null | head -1 | awk '{print $2}')"

  local pid
  pid=$(pgrep -o apache2 2>/dev/null || true)
  if [ -n "$pid" ] && grep -q 'libphp8.2.so (deleted)' "/proc/$pid/maps" 2>/dev/null; then
    note "Apache держит удалённую libphp — рестарт apache2"
    systemctl restart apache2 || die "apache2 не перезапустился"
    sleep 2
    pid=$(pgrep -o apache2 2>/dev/null || true)
    if [ -n "$pid" ] && grep -q 'libphp8.2.so (deleted)' "/proc/$pid/maps" 2>/dev/null; then
      note "ВНИМАНИЕ: libphp всё ещё (deleted)"
    else
      note "libphp актуальна"
    fi
  else
    note "рестарт Apache не нужен"
  fi

  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/admin/ 2>/dev/null)
  note "GUI http://127.0.0.1/admin/ → HTTP $code"
}

# ---------------------------------------------------------------------------
[ $DO_STATUS -eq 1 ] && status
[ $DO_UPDATE -eq 1 ] && update_modules
[ $DO_PHP    -eq 1 ] && update_php

say "Готово"
note "Лог: $LOG"
