# freepbx-install

Скрипты установки и обслуживания FreePBX 17 на Debian 12.

Собраны в Techwave Solutions для повторяемого развёртывания АТС у клиентов:
одинаковый состав модулей на всех площадках, без коммерческих компонентов
и без репозитория Sangoma.

## Что внутри

| Файл | Назначение |
|---|---|
| `fpbx-scratch.sh` | Установка с нуля на чистый Debian 12: Asterisk 21 из исходников, PHP 8.2, MariaDB, Apache, FreePBX 17 из upstream-tarball |
| `fpbx-lean.sh` | Прунинг уже установленной системы: удаление модулей вне белого списка |
| `fpbx-maint.sh` | Обслуживание работающей АТС: обновление модулей, security-обновление PHP с рестартом Apache |

## Установка

Все команды выполняются от root.

### Оба скрипта одной строкой

```bash
cd /root
for f in fpbx-scratch.sh fpbx-lean.sh fpbx-maint.sh; do
  wget -q https://raw.githubusercontent.com/Rufa-TEST/freepbx-install/main/$f -O /root/$f \
    && chmod +x /root/$f && echo "$f — ok"
done
ls -l /root/fpbx-*.sh
```

### Только установщик с нуля

```bash
wget https://raw.githubusercontent.com/Rufa-TEST/freepbx-install/main/fpbx-scratch.sh -O /root/fpbx-scratch.sh
chmod +x /root/fpbx-scratch.sh
/root/fpbx-scratch.sh --all
```

### Только прунинг

```bash
wget https://raw.githubusercontent.com/Rufa-TEST/freepbx-install/main/fpbx-lean.sh -O /root/fpbx-lean.sh
chmod +x /root/fpbx-lean.sh
/root/fpbx-lean.sh --prune
```

### Весь репозиторий

```bash
apt-get install -y git
git clone https://github.com/Rufa-TEST/freepbx-install.git /root/freepbx-install
chmod +x /root/freepbx-install/*.sh
```

Обновить уже склонированный:

```bash
git -C /root/freepbx-install pull
```

### Проверка

```bash
/root/fpbx-scratch.sh --status   # состояние системы
/root/fpbx-lean.sh --list        # состав модулей с пометками keep/drop
/root/fpbx-maint.sh --status     # версии, звонки, записи, состояние PHP
```

## fpbx-scratch.sh

Отличие от штатного инсталлятора Sangoma: вместо `fwconsole ma installall`
ставится заданный список модулей. Репозиторий Sangoma не подключается,
поэтому коммерческих модулей (`sysadmin`, `firewall`) на выходе нет.

Запуск без аргументов открывает меню с выбором по цифрам. Ключи для
неинтерактивного режима:

```
./fpbx-scratch.sh --all         # всё целиком (включая финальный шаг --post)
./fpbx-scratch.sh --deps        # только пакеты
./fpbx-scratch.sh --asterisk    # только сборка Asterisk (20-40 минут)
./fpbx-scratch.sh --freepbx     # только FreePBX + модули
./fpbx-scratch.sh --modules     # только доустановка модулей
./fpbx-scratch.sh --post        # финал: ma upgradeall, security-обновление PHP, MIXMON_FORMAT=wav
./fpbx-scratch.sh --own         # свои модули из OWN_MODULES
./fpbx-scratch.sh --status      # состояние системы
```

Скрипт идемпотентен: повторный запуск пропускает уже выполненные шаги.

В `--all` входит финальный шаг `--post`: обновление модулей FreePBX до актуальных,
security-обновление `php8.2*` с рестартом Apache (если `libphp8.2.so (deleted)`)
и `MIXMON_FORMAT=wav`. Для уже работающей АТС то же самое по отдельности — `fpbx-maint.sh`.
Запись на маршрутах (Inbound/Outbound → «Запись вызова» = Да) включается в GUI.

### Настройка

В шапке файла:

- `ASTERISK_MAJOR` — ветка Asterisk. По умолчанию 21 (сочетание с FreePBX 17
  протестировано Sangoma). 20 — LTS, 22 — свежее.
- `MODULES` — список модулей FreePBX.
- `OWN_MODULES` — URL на tarball собственных модулей, ставятся через
  `fwconsole ma downloadinstall <url>`.

### Требования

Чистый Debian 12 (bookworm), x86_64. На Debian 13 инсталлятор FreePBX
не работает — скрипт это проверяет и прерывается.

## fpbx-lean.sh

Приводит уже работающую систему к тому же составу модулей.

```
./fpbx-lean.sh --list           # что стоит, с пометками keep/drop
./fpbx-lean.sh --prune          # показать, что будет удалено
./fpbx-lean.sh --prune --apply  # удалить
./fpbx-lean.sh --ensure         # доустановить недостающее
```

Без `--apply` ничего не удаляется.

## fpbx-maint.sh

Обслуживание уже работающей АТС. Asterisk не перезапускается, при активных
звонках скрипт останавливается (обойти: `--force`).

```
./fpbx-maint.sh --status        # версии, звонки, место под записи, пустые файлы
./fpbx-maint.sh --update        # бэкап (/etc/asterisk + дамп БД) → ma upgradeall → chown → reload
./fpbx-maint.sh --php           # apt --only-upgrade php8.2* → рестарт Apache, если libphp (deleted)
```

Про PHP: после обновления пакетов mod_php Apache продолжает держать старую
`libphp8.2.so (deleted)`, и GUI работает на старой версии (уведомление на
дашборде не уходит), пока Apache не перезапущен. Рестарт Apache звонки не
затрагивает.

### Записи разговоров

Настраивается в GUI: Inbound/Outbound Routes → «Запись вызова» = Да (один файл
на звонок; запись на уровне внутренних даёт отдельный файл на каждую ногу
ringall). Формат оставлять `wav` (`MIXMON_FORMAT`): GSM `WAV` не играет в
браузере, а mp3 под именем `.wav` ломает просмотр в CDR (sox: «RIFF header not
found»). Неотвеченные звонки оставляют пустые файлы 44 байта — их безопасно
чистить `find /var/spool/asterisk/monitor -type f -size -101c -mtime +1`.

## Ручная чистка коммерческих модулей

Если система уже развёрнута штатным инсталлятором Sangoma и нужно снять
коммерческие модули, не подгоняя состав под белый список `fpbx-lean.sh`.

Порядок и грабли, проверенные на живой системе:

- `fwconsole ma uninstall` возвращает 0 даже при ошибке — результат проверять
  перечитыванием `fwconsole ma list`, а не кодом возврата.
- Зависимости требуют нескольких проходов: `cos`, `restapps`, `sms` уходят со
  второго, `endpoint` — с третьего.
- `ucp` не удаляется, пока стоит `webrtc` (webrtc зависит от ucp) — порядок
  строго `webrtc` → `ucp`.
- `sysadmin` нужен для `firewall`; если firewall не используется, снимаются оба.

```bash
# что стоит из коммерческих
fwconsole ma list | awk -F'|' '$5 ~ /Commercial/ {print $2}'

# снять модуль
fwconsole ma uninstall <модуль> && fwconsole ma delete <модуль>

# после всех удалений
fwconsole reload

# мёртвые процессы pm2 остаются в списке — убрать
fwconsole pm2 --list
fwconsole pm2 --delete <имя>
```

Вернуть модуль обратно:

```bash
fwconsole ma downloadinstall <модуль>
```

## Лишние системные сервисы

После сноса модулей часть сервисов остаётся работать впустую. Сначала смотреть,
что реально слушает порты:

```bash
systemctl list-units --type=service --state=running --no-pager
ss -tulpn | grep -E "haproxy|tftp|redis|avahi|pnpd"
```

| Сервис | Когда можно гасить |
|---|---|
| `sangoma-pnpd` | автопровижининг Sangoma — не нужен без Endpoint Manager |
| `avahi-daemon` | mDNS в локалке, телефонии не нужен |
| `haproxy` | в FreePBX 17 фронтит UCP/WebRTC; если в `haproxy.cfg` нет `bind` — висит впустую |
| `tftpd-hpa`, `xinetd` | раздача конфигов телефонам; гасить только если `/tftpboot` пуст |
| `postfix` | только отправка почты (голосовая почта на email) |

Не трогать: `redis-server` и `incron` — на них завязаны кэш фреймворка и
отслеживание изменений конфигов.

```bash
systemctl disable --now sangoma-pnpd avahi-daemon haproxy

# avahi поднимется обратно по socket-активации — закрыть и его
systemctl disable --now avahi-daemon.socket
systemctl mask avahi-daemon.service avahi-daemon.socket
```

`tftpd-hpa` и `xinetd` — sysv-скрипты: `systemctl disable --now` снимает
автозапуск, но процесс не убивает. Добивать так:

```bash
systemctl disable --now tftpd-hpa xinetd
service tftpd-hpa stop; service xinetd stop
systemctl is-active tftpd-hpa xinetd
ss -tulpn | grep ":69"
```

## Проверено на

- Debian 12.x / Asterisk 21.12.3 / FreePBX 17.0.33 / PHP 8.2

## Лицензия

GPL-3.0
