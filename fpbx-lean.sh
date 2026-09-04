#!/bin/bash
#
# fpbx-lean.sh — установка FreePBX 17 на Debian 12 с минимальным набором модулей.
#
# Фазы:
#   1) install  — штатный sng_freepbx_debian_install.sh с --opensourceonly
#   2) prune    — удаление всех модулей, которых нет в белом списке KEEP
#   3) ensure   — доустановка модулей из KEEP, которых не оказалось
#
# По умолчанию prune работает вхолостую и только показывает список.
# Реальное удаление — только с ключом --apply.
#
# Использование:
#   ./fpbx-lean.sh --all            # установка + прунинг (dry-run) + доустановка
#   ./fpbx-lean.sh --prune          # только показать, что будет удалено
#   ./fpbx-lean.sh --prune --apply  # удалить
#   ./fpbx-lean.sh --ensure         # доустановить недостающее из KEEP
#   ./fpbx-lean.sh --list           # что стоит сейчас, с пометками keep/drop
#
set -uo pipefail

# ---------------------------------------------------------------------------
# БЕЛЫЙ СПИСОК. Правится под задачу — это единственное место, которое нужно
# трогать. Модули не из этого списка будут удалены на фазе prune.
# ---------------------------------------------------------------------------
KEEP=(
  # ядро и обвязка
  framework core dashboard sipsettings featurecodeadmin logfiles manager
  arimanager pm2 filestore certman customappsreg soundlang infoservices
  userman languages backup

  # телефония, повседневное
  extensionsettings voicemail callrecording recordings music cdr cel
  ivr ringgroups queues announcement timeconditions daynight
  callforward donotdisturb callwaiting findmefollow miscapps miscdests
  conferences parking paging blacklist allowlist bulkhandler

  # диагностика и свои модули
  asteriskinfo asterisk-cli configedit bulkext
)

# Модули, которые FreePBX не даст удалить или которые сломают установку.
# Держим отдельно от KEEP, чтобы список выше оставался читаемым.
PROTECTED=(framework core)

SNG_URL="https://github.com/FreePBX/sng_freepbx_debian_install/raw/master/sng_freepbx_debian_install.sh"
LOG="/var/log/fpbx-lean-$(date +%Y%m%d-%H%M%S).log"

APPLY=0
DO_INSTALL=0
DO_PRUNE=0
DO_ENSURE=0
DO_LIST=0

say()  { echo -e "\n=== $* ==="; }
note() { echo "  $*"; }

usage() { sed -n '2,22p' "$0"; exit 1; }

for a in "$@"; do
  case "$a" in
    --all)     DO_INSTALL=1; DO_PRUNE=1; DO_ENSURE=1 ;;
    --install) DO_INSTALL=1 ;;
    --prune)   DO_PRUNE=1 ;;
    --ensure)  DO_ENSURE=1 ;;
    --list)    DO_LIST=1 ;;
    --apply)   APPLY=1 ;;
    *) usage ;;
  esac
done
[ $# -eq 0 ] && usage
[ "$(id -u)" -eq 0 ] || { echo "Нужен root"; exit 1; }

in_keep() {
  local m="$1" k
  for k in "${KEEP[@]}" "${PROTECTED[@]}"; do [ "$k" = "$m" ] && return 0; done
  return 1
}

# Список установленных модулей (rawname).
installed_modules() {
  # Таблица fwconsole локализована (Включен/Enabled), поэтому по статусу не
  # ориентируемся: берём строки с именем модуля и непустой версией.
  fwconsole ma list 2>/dev/null | awk -F'|' '
    NF>=5 {
      name=$2; ver=$3;
      gsub(/^[ \t]+|[ \t]+$/,"",name); gsub(/^[ \t]+|[ \t]+$/,"",ver);
      if (name=="" || ver=="") next;          # шапка и псевдомодуль builtin
      if (name ~ /[^a-z0-9_.-]/) next;        # "Модуль"/"Module" и разделители
      print name
    }'
}

# ---------------------------------------------------------------------------
# 1) Установка
# ---------------------------------------------------------------------------
if [ $DO_INSTALL -eq 1 ]; then
  say "Проверка окружения"
  . /etc/os-release
  note "ОС: $PRETTY_NAME"
  if [ "${VERSION_ID:-}" != "12" ]; then
    echo "  ВНИМАНИЕ: инсталлятор Sangoma официально поддерживает только Debian 12 (bookworm)."
    echo "  На 13/trixie он не отработает. Прерываю."
    exit 1
  fi

  if command -v fwconsole >/dev/null 2>&1; then
    note "FreePBX уже установлен — фазу установки пропускаю."
  else
    say "Установка FreePBX 17 (opensourceonly)"
    apt-get update
    apt-get install -y wget ca-certificates
    wget -q "$SNG_URL" -O /tmp/sng_freepbx_debian_install.sh || { echo "Не скачался инсталлятор"; exit 1; }
    note "Лог установки Sangoma: /var/log/pbx/"
    bash /tmp/sng_freepbx_debian_install.sh --opensourceonly 2>&1 | tee -a "$LOG"
    command -v fwconsole >/dev/null 2>&1 || { echo "Установка не завершилась, смотри /var/log/pbx/"; exit 1; }
  fi
fi

command -v fwconsole >/dev/null 2>&1 || { echo "fwconsole не найден — сначала --install"; exit 1; }

# ---------------------------------------------------------------------------
# --list
# ---------------------------------------------------------------------------
if [ $DO_LIST -eq 1 ]; then
  say "Установленные модули"
  while read -r m; do
    [ -z "$m" ] && continue
    if in_keep "$m"; then printf "  %-24s keep\n" "$m"; else printf "  %-24s DROP\n" "$m"; fi
  done < <(installed_modules)
fi

# ---------------------------------------------------------------------------
# 2) Прунинг
# ---------------------------------------------------------------------------
if [ $DO_PRUNE -eq 1 ]; then
  say "Прунинг по белому списку"
  mapfile -t drop < <(installed_modules | while read -r m; do in_keep "$m" || echo "$m"; done)

  if [ ${#drop[@]} -eq 0 ]; then
    note "Лишних модулей нет."
  elif [ $APPLY -eq 0 ]; then
    note "Будут удалены (${#drop[@]}):"
    printf '    %s\n' "${drop[@]}"
    note "Ключ --apply выполнит удаление."
  else
    # несколько проходов: зависимые модули удаляются раньше тех, от кого зависят
    for pass in 1 2 3; do
      left=()
      for m in "${drop[@]}"; do
        if fwconsole ma remove "$m" >>"$LOG" 2>&1; then
          note "удалён: $m"
        else
          left+=("$m")
        fi
      done
      drop=("${left[@]}")
      [ ${#drop[@]} -eq 0 ] && break
    done
    if [ ${#drop[@]} -gt 0 ]; then
      note "Не удалились (зависимости или защита):"
      printf '    %s\n' "${drop[@]}"
      note "Подробности: $LOG"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 3) Доустановка
# ---------------------------------------------------------------------------
if [ $DO_ENSURE -eq 1 ]; then
  say "Доустановка модулей из белого списка"
  present=$(installed_modules)
  for m in "${KEEP[@]}"; do
    if grep -qx "$m" <<<"$present"; then
      continue
    fi
    if [ $APPLY -eq 0 ]; then
      note "будет установлен: $m"
    else
      if fwconsole ma downloadinstall "$m" >>"$LOG" 2>&1; then
        note "установлен: $m"
      else
        note "НЕ установлен: $m (нет в репозитории или конфликт) — см. $LOG"
      fi
    fi
  done
fi

if [ $APPLY -eq 1 ] && { [ $DO_PRUNE -eq 1 ] || [ $DO_ENSURE -eq 1 ]; }; then
  say "Применение конфигурации"
  fwconsole chown >>"$LOG" 2>&1
  fwconsole reload 2>&1 | tail -5
fi

say "Готово"
note "Лог: $LOG"
