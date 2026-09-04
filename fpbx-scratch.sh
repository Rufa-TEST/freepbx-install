#!/bin/bash
#
# fpbx-scratch.sh — установка FreePBX 17 на чистый Debian 12 из исходников,
# без репозитория Sangoma и без коммерческих модулей.
#
# Основано на официальном мануале Sangoma "How to Install FreePBX 17 on
# Debian 12 with Asterisk 21", с одним отличием: вместо `fwconsole ma installall`
# ставится только список MODULES.
#
# Состав: Asterisk 21 (сборка из исходников), PHP 8.2, MariaDB, Apache,
#         FreePBX 17 из tarball mirror.freepbx.org.
#
# Использование:
#   ./fpbx-scratch.sh --all             # всё целиком
#   ./fpbx-scratch.sh --deps            # только пакеты
#   ./fpbx-scratch.sh --asterisk        # только сборка Asterisk
#   ./fpbx-scratch.sh --freepbx         # только FreePBX + модули
#   ./fpbx-scratch.sh --modules         # только доустановка модулей
#
# Скрипт идемпотентен: повторный запуск пропускает уже сделанные шаги.
# Сборка Asterisk занимает 20-40 минут.
#
set -uo pipefail

ASTERISK_MAJOR="${ASTERISK_MAJOR:-21}"     # 20 = LTS, 21 = по мануалу, 22 = свежее
FREEPBX_TGZ="http://mirror.freepbx.org/modules/packages/freepbx/freepbx-17.0-latest-EDGE.tgz"
LOG="/var/log/fpbx-scratch-$(date +%Y%m%d-%H%M%S).log"

# ---------------------------------------------------------------------------
# Модули, которые будут установлены вместо `fwconsole ma installall`.
# Часть уже входит в tarball — такие просто пропустятся.
# ---------------------------------------------------------------------------
MODULES=(
  # обвязка
  framework core dashboard sipsettings featurecodeadmin logfiles manager
  arimanager pm2 filestore certman customappsreg soundlang infoservices
  userman languages backup

  # телефония
  extensionsettings voicemail callrecording recordings music cdr cel
  ivr ringgroups queues announcement timeconditions daynight
  callforward donotdisturb callwaiting findmefollow miscapps miscdests
  conferences parking paging blacklist allowlist bulkhandler

  # диагностика
  asteriskinfo asterisk-cli configedit
)

# Свои модули: URL на tarball (GitHub Releases или локальный путь).
OWN_MODULES=(
  # https://github.com/<аккаунт>/twtools/releases/latest/download/twtools.tgz
)

DO_DEPS=0; DO_AST=0; DO_FPBX=0; DO_MODS=0; DO_OWN=0; DO_STATUS=0
say()  { echo -e "\n=== $* ===" | tee -a "$LOG"; }
note() { echo "  $*" | tee -a "$LOG"; }
die()  { echo "ОШИБКА: $*" | tee -a "$LOG"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "нужен root"

# --- состояние системы, показывается в меню ---
status_line() {
  local ok_ast ok_fpbx ok_php
  command -v asterisk  >/dev/null 2>&1 && ok_ast="$(asterisk -V 2>/dev/null)" || ok_ast="нет"
  command -v fwconsole >/dev/null 2>&1 && ok_fpbx="$(fwconsole --version 2>/dev/null | head -1)" || ok_fpbx="нет"
  command -v php >/dev/null 2>&1 && ok_php="$(php -v 2>/dev/null | head -1 | awk '{print $2}')" || ok_php="нет"
  echo "  Asterisk: $ok_ast"
  echo "  FreePBX:  $ok_fpbx"
  echo "  PHP:      $ok_php"
  if command -v fwconsole >/dev/null 2>&1; then
    echo "  Модулей:  $(fwconsole ma list 2>/dev/null | grep -c '^|')"
  fi
}

menu() {
  while true; do
    echo
    echo "======================================================"
    echo "  FreePBX 17 — установка на чистый Debian 12"
    echo "======================================================"
    status_line
    echo "------------------------------------------------------"
    echo "  1) Полная установка (пакеты + Asterisk + FreePBX)"
    echo "  2) Только пакеты"
    echo "  3) Только Asterisk (сборка из исходников, 20-40 мин)"
    echo "  4) Только FreePBX + модули"
    echo "  5) Только доустановка модулей по списку"
    echo "  6) Свои модули Techwave"
    echo "  9) Состояние системы"
    echo "  0) Выход"
    echo "------------------------------------------------------"
    read -rp "  Выбор: " ch
    case "$ch" in
      1) DO_DEPS=1; DO_AST=1; DO_FPBX=1; DO_MODS=1; return ;;
      2) DO_DEPS=1; return ;;
      3) DO_AST=1; return ;;
      4) DO_FPBX=1; DO_MODS=1; return ;;
      5) DO_MODS=1; return ;;
      6) DO_OWN=1; return ;;
      9) echo; status_line ;;
      0) exit 0 ;;
      *) echo "  Нет такого пункта." ;;
    esac
  done
}

if [ $# -eq 0 ]; then
  menu
else
  for a in "$@"; do
    case "$a" in
      --all) DO_DEPS=1; DO_AST=1; DO_FPBX=1; DO_MODS=1 ;;
      --deps) DO_DEPS=1 ;;
      --asterisk) DO_AST=1 ;;
      --freepbx) DO_FPBX=1; DO_MODS=1 ;;
      --modules) DO_MODS=1 ;;
      --own) DO_OWN=1 ;;
      --status) DO_STATUS=1 ;;
      *) sed -n '2,18p' "$0"; exit 1 ;;
    esac
  done
fi

if [ $DO_STATUS -eq 1 ]; then status_line; exit 0; fi

. /etc/os-release
[ "${VERSION_ID:-}" = "12" ] || die "поддерживается только Debian 12 (bookworm), здесь: $PRETTY_NAME"
[ "$(uname -m)" = "x86_64" ] || die "нужен x86_64"

# ---------------------------------------------------------------------------
# 1. Пакеты
# ---------------------------------------------------------------------------
if [ $DO_DEPS -eq 1 ]; then
  say "Установка пакетов"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update >>"$LOG" 2>&1
  apt-get -y upgrade >>"$LOG" 2>&1

  if php -v 2>/dev/null | grep -q "^PHP 8\.[013-9]"; then
    die "стоит PHP не 8.2 — FreePBX 17 работает только с 8.2, снимите текущую версию вручную"
  fi

  apt-get -y install build-essential git curl wget libnewt-dev libssl-dev \
    libncurses5-dev subversion libsqlite3-dev libjansson-dev libxml2-dev uuid-dev \
    default-libmysqlclient-dev htop sngrep lame ffmpeg mpg123 expect vim \
    linux-headers-"$(uname -r)" openssh-server apache2 mariadb-server mariadb-client \
    bison flex php8.2 php8.2-curl php8.2-cli php8.2-common php8.2-mysql php8.2-gd \
    php8.2-mbstring php8.2-intl php8.2-xml php-pear sox pkg-config automake libtool \
    autoconf unixodbc-dev uuid libasound2-dev libogg-dev libvorbis-dev libicu-dev \
    libcurl4-openssl-dev odbc-mariadb libical-dev libneon27-dev libsrtp2-dev \
    libspandsp-dev sudo libtool-bin python-dev-is-python3 unixodbc \
    software-properties-common nodejs npm ipset iptables fail2ban php-soap sqlite3 \
    >>"$LOG" 2>&1 || die "не поставились пакеты, см. $LOG"
  note "готово"
fi

# ---------------------------------------------------------------------------
# 2. Asterisk из исходников
# ---------------------------------------------------------------------------
if [ $DO_AST -eq 1 ]; then
  if command -v asterisk >/dev/null 2>&1; then
    note "Asterisk уже установлен ($(asterisk -V 2>/dev/null)) — сборку пропускаю"
  else
    say "Сборка Asterisk $ASTERISK_MAJOR (20-40 минут)"
    cd /usr/src || die "нет /usr/src"
    tgz="asterisk-${ASTERISK_MAJOR}-current.tar.gz"
    [ -f "$tgz" ] || wget -q "http://downloads.asterisk.org/pub/telephony/asterisk/$tgz" \
      || die "не скачался Asterisk"
    rm -rf /usr/src/asterisk-"${ASTERISK_MAJOR}".*/
    tar xf "$tgz"
    src=$(find /usr/src -maxdepth 1 -type d -name "asterisk-${ASTERISK_MAJOR}.*" | head -1)
    cd "$src" || die "не распаковался Asterisk"

    contrib/scripts/get_mp3_source.sh >>"$LOG" 2>&1
    contrib/scripts/install_prereq install >>"$LOG" 2>&1

    ./configure --libdir=/usr/lib64 --with-pjproject-bundled --with-jansson-bundled >>"$LOG" 2>&1 \
      || die "configure не отработал, см. $LOG"

    # menuselect без интерактива: включаем то, что нужно FreePBX
    make menuselect.makeopts >>"$LOG" 2>&1
    menuselect/menuselect --enable format_mp3 --enable res_srtp \
      --enable CORE-SOUNDS-EN-WAV --enable MOH-OPSOUND-WAV --enable EXTRA-SOUNDS-EN-WAV \
      menuselect.makeopts >>"$LOG" 2>&1

    make -j"$(nproc)" >>"$LOG" 2>&1 || die "сборка не прошла, см. $LOG"
    make install >>"$LOG" 2>&1
    make samples >>"$LOG" 2>&1
    ldconfig
    note "Asterisk собран"
  fi

  say "Пользователь asterisk и права"
  getent group asterisk >/dev/null || groupadd asterisk
  id asterisk >/dev/null 2>&1 || useradd -r -d /var/lib/asterisk -g asterisk asterisk
  usermod -aG audio,dialout asterisk
  chown -R asterisk:asterisk /etc/asterisk
  chown -R asterisk:asterisk /var/lib/asterisk /var/log/asterisk /var/spool/asterisk
  [ -d /usr/lib64/asterisk ] && chown -R asterisk:asterisk /usr/lib64/asterisk
  sed -i 's|#AST_USER|AST_USER|; s|#AST_GROUP|AST_GROUP|' /etc/default/asterisk 2>/dev/null
  sed -i 's|;runuser|runuser|; s|;rungroup|rungroup|' /etc/asterisk/asterisk.conf
  grep -q "^/usr/lib64$" /etc/ld.so.conf.d/x86_64-linux-gnu.conf 2>/dev/null || \
    echo "/usr/lib64" >> /etc/ld.so.conf.d/x86_64-linux-gnu.conf
  ldconfig
  note "готово"

  say "Apache, PHP, ODBC"
  sed -i 's/\(^upload_max_filesize = \).*/\120M/' /etc/php/8.2/apache2/php.ini
  sed -i 's/\(^memory_limit = \).*/\1256M/' /etc/php/8.2/apache2/php.ini
  sed -i 's/^\(User\|Group\).*/\1 asterisk/' /etc/apache2/apache2.conf
  sed -i 's/AllowOverride None/AllowOverride All/' /etc/apache2/apache2.conf
  a2enmod rewrite >>"$LOG" 2>&1
  systemctl restart apache2
  rm -f /var/www/html/index.html

  cat > /etc/odbcinst.ini <<'EOF'
[MySQL]
Description = ODBC for MySQL (MariaDB)
Driver = /usr/lib/x86_64-linux-gnu/odbc/libmaodbc.so
FileUsage = 1
EOF
  cat > /etc/odbc.ini <<'EOF'
[MySQL-asteriskcdrdb]
Description = MySQL connection to 'asteriskcdrdb' database
Driver = MySQL
Server = localhost
Database = asteriskcdrdb
Port = 3306
Socket = /var/run/mysqld/mysqld.sock
Option = 3
EOF
  note "готово"
fi

# ---------------------------------------------------------------------------
# 3. FreePBX
# ---------------------------------------------------------------------------
if [ $DO_FPBX -eq 1 ]; then
  if command -v fwconsole >/dev/null 2>&1; then
    note "FreePBX уже установлен — установку пропускаю"
  else
    say "Установка FreePBX 17"
    command -v asterisk >/dev/null 2>&1 || die "сначала Asterisk (--asterisk)"
    systemctl is-active --quiet mariadb || systemctl start mariadb

    cd /usr/local/src || die "нет /usr/local/src"
    [ -f freepbx-17.0-latest-EDGE.tgz ] || wget -q "$FREEPBX_TGZ" || die "не скачался FreePBX"
    rm -rf /usr/local/src/freepbx
    tar zxf freepbx-17.0-latest-EDGE.tgz
    cd /usr/local/src/freepbx || die "не распаковался FreePBX"

    ./start_asterisk start >>"$LOG" 2>&1
    ./install -n 2>&1 | tee -a "$LOG" | tail -20
    command -v fwconsole >/dev/null 2>&1 || die "install не завершился, см. $LOG"
  fi

  say "systemd-юнит"
  cat > /etc/systemd/system/freepbx.service <<'EOF'
[Unit]
Description=FreePBX VoIP Server
After=mariadb.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/fwconsole start -q
ExecStop=/usr/sbin/fwconsole stop -q

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable freepbx >>"$LOG" 2>&1
  note "готово"
fi

# ---------------------------------------------------------------------------
# 4. Модули по списку (вместо fwconsole ma installall)
# ---------------------------------------------------------------------------
if [ $DO_MODS -eq 1 ]; then
  command -v fwconsole >/dev/null 2>&1 || die "FreePBX не установлен"
  say "Установка модулей (${#MODULES[@]} шт.)"

  present=$(fwconsole ma list 2>/dev/null | awk -F'|' '
    NF>=5 { name=$2; ver=$3;
      gsub(/^[ \t]+|[ \t]+$/,"",name); gsub(/^[ \t]+|[ \t]+$/,"",ver);
      if (name=="" || ver=="") next;
      if (name ~ /[^a-z0-9_.-]/) next;
      print name }')

  failed=()
  for m in "${MODULES[@]}"; do
    if grep -qx "$m" <<<"$present"; then
      note "уже стоит: $m"
      continue
    fi
    if fwconsole ma downloadinstall "$m" >>"$LOG" 2>&1; then
      note "установлен: $m"
    else
      note "НЕ установлен: $m"
      failed+=("$m")
    fi
  done

  say "Применение конфигурации"
  fwconsole chown >>"$LOG" 2>&1
  fwconsole reload 2>&1 | tail -5 | tee -a "$LOG"
  fwconsole restart >>"$LOG" 2>&1

  if [ ${#failed[@]} -gt 0 ]; then
    note "Не установились: ${failed[*]} — подробности в $LOG"
  fi
fi

# --- 5. Свои модули Techwave ---
if [ $DO_OWN -eq 1 ]; then
  command -v fwconsole >/dev/null 2>&1 || die "FreePBX не установлен"
  say "Установка своих модулей (${#OWN_MODULES[@]} шт.)"
  for u in "${OWN_MODULES[@]}"; do
    n=$(basename "$u")
    if fwconsole ma downloadinstall "$u" >>"$LOG" 2>&1; then
      note "установлен: $n"
    else
      note "НЕ установлен: $n — см. $LOG"
    fi
  done
  fwconsole chown >>"$LOG" 2>&1
  fwconsole reload 2>&1 | tail -3 | tee -a "$LOG"
fi

say "Готово"
note "Лог: $LOG"
note "GUI: http://$(hostname -I | awk '{print $1}')/admin"
note "Первый вход создаёт учётку администратора."
