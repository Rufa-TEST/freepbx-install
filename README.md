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

## fpbx-scratch.sh

Отличие от штатного инсталлятора Sangoma: вместо `fwconsole ma installall`
ставится заданный список модулей. Репозиторий Sangoma не подключается,
поэтому коммерческих модулей (`sysadmin`, `firewall`) на выходе нет.

Запуск без аргументов открывает меню с выбором по цифрам. Ключи для
неинтерактивного режима:

```
./fpbx-scratch.sh --all         # всё целиком
./fpbx-scratch.sh --deps        # только пакеты
./fpbx-scratch.sh --asterisk    # только сборка Asterisk (20-40 минут)
./fpbx-scratch.sh --freepbx     # только FreePBX + модули
./fpbx-scratch.sh --modules     # только доустановка модулей
./fpbx-scratch.sh --own         # свои модули из OWN_MODULES
./fpbx-scratch.sh --status      # состояние системы
```

Скрипт идемпотентен: повторный запуск пропускает уже выполненные шаги.

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

## Проверено на

- Debian 12.x / Asterisk 21.12.3 / FreePBX 17.0.33 / PHP 8.2

## Лицензия

GPL-3.0
