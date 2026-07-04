# remnanode-setup

Автоматическая установка **ноды Remnawave** на чистый Debian/Ubuntu-сервер: VLESS (Reality/Vision + XHTTP), Trojan и Hysteria2 за **Caddy L4** с SNI-роутингом. Один запуск — и нода готова к подключению к панели.

Скрипт идемпотентный: повторный запуск не ломает уже настроенное (сборка Caddy, сертификаты, `.env` — всё пропускается или переиспользуется).

---

## Что делает

- **Preflight** — проверка ОС, архитектуры, ядра (BBR), RAM и диска.
- **Docker** — установка через `get.docker.com`, ротация логов, `live-restore`.
- **Caddy + caddy-l4** — сборка кастомного бинаря через `xcaddy` с модулем [`mholt/caddy-l4`](https://github.com/mholt/caddy-l4), `setcap` на биндинг привилегированных портов.
- **L4-роутинг по SNI** на `:443/tcp`:
  | SNI | → | Локальный порт | Инбаунд |
  |-----|---|----------------|---------|
  | `VISION_SNI` (маскировка, напр. `www.google.com`) | → | `127.0.0.1:10443` | VLESS Reality + Vision |
  | `XHTTP_SNI` | → | `127.0.0.1:10444` | VLESS XHTTP |
  | `TROJAN_HOST` | → | `127.0.0.1:10445` | Trojan (TLS) |
  | *остальное* | → | `VISION_SNI:443` | self-steal fallback |
- **Hysteria2** — слушает `:443/udp` напрямую из контейнера (host-network), в обход Caddy.
- **Сертификаты** — `acme.sh` (Let's Encrypt, EC-256) для `TROJAN_HOST` и `HY_HOST`, установка в `/etc/remna-certs`, автоперевыпуск, reload через `docker restart remnanode`.
- **sysctl-тюнинг** — BBR + `fq`, UDP-буферы, backlog, `nofile` до 1 048 576.
- **Firewall (ufw)** — SSH, `443/tcp`, `443/udp`, `80/tcp` (acme), а API-порт ноды — **только с IP панели**.
- **Нода Remnawave** — `docker-compose.yml` + `.env` (0600), `network_mode: host`, `NET_ADMIN`, ротация логов, health-poll после старта.

---

## Требования

- Debian 11/12 или Ubuntu 20.04+ (`amd64` или `arm64`), root-доступ.
- Минимум ~1 GB RAM и ~3 GB свободного диска (сборка Go + Docker).
- Три A-записи на **IP ноды** (по умолчанию префикс `usa`):

  | Домен | Назначение | Нужен валидный сертификат |
  |-------|-----------|---------------------------|
  | `<prefix>1.<domain>` | адрес подключения VLESS (SNI подменяется на `VISION_SNI`) | нет (Reality) |
  | `<prefix>2.<domain>` | Trojan | **да** |
  | `<prefix>3.<domain>` | Hysteria2 | **да** |

- Панель Remnawave, где заранее создаётся нода — она выдаёт `SECRET_KEY`.

---

## Быстрый старт

Через process substitution (stdin остаётся свободным для интерактивных вопросов):

```bash
apt-get update && apt-get install -y curl; \
bash <(curl -fsSL https://raw.githubusercontent.com/1atex/node-balancer/main/remnanode-setup.sh)
```

Либо скачать, просмотреть и запустить:

```bash
curl -fsSL https://raw.githubusercontent.com/1atex/node-balancer/main/remnanode-setup.sh -o remnanode-setup.sh
less remnanode-setup.sh          # инспекция перед запуском
bash remnanode-setup.sh
```

> Скрипт спросит: базовый домен, префикс, маскировочные SNI, путь XHTTP, IP панели, порт API и `SECRET_KEY`. Ответы сохраняются в `/root/remnanode.env` и переиспользуются при следующем запуске.

### Порядок действий

1. Поднимите A-записи `<prefix>1/2/3` на IP ноды.
2. В панели: **Nodes → Add** — укажите IP ноды и порт API (по умолчанию `2222`), скопируйте `SECRET_KEY`.
3. Запустите скрипт, вставьте `SECRET_KEY` на шаге 9.
4. Настройте инбаунды в панели на локальные порты `10443` / `10444` / `10445` и Hysteria2 на `443/udp` (карта — в финальном выводе скрипта).
5. Дождитесь статуса **online** у ноды.

---

## Неинтерактивный режим (CI / массовый деплой)

Все параметры можно передать через переменные окружения:

```bash
BASE_DOMAIN=example.com \
PREFIX=usa \
VISION_SNI=www.google.com \
XHTTP_SNI=www.gstatic.com \
XHTTP_PATH=/api/v3/sync/r1 \
PANEL_IP=203.0.113.10 \
NODE_API_PORT=2222 \
SECRET_KEY='eyJ...' \
bash <(curl -fsSL https://raw.githubusercontent.com/1atex/node-balancer/main/remnanode-setup.sh) \
  --non-interactive --yes
```

---

## Флаги

```
--no-compose          не трогать docker-compose.yml (только .env + up -d)
--no-firewall         не настраивать ufw
--no-reset-firewall   не делать 'ufw reset' (сохранить существующие правила)
--force-dns           не прерываться при несовпадении DNS
--ssh-port N          явно указать SSH-порт для правила ufw
--node-image REF      образ ноды (по умолчанию remnawave/node:latest)
-y | --yes            авто-подтверждение всех y/n вопросов
--non-interactive     не задавать вопросы: значения из env/дефолтов
-h | --help           справка
```

**Переменные окружения:** `BASE_DOMAIN`, `PREFIX`, `VISION_SNI`, `XHTTP_SNI`, `XHTTP_PATH`, `PANEL_IP`, `NODE_API_PORT`, `SECRET_KEY`, `NODE_IMAGE`, а также пути `NODE_DIR`, `CERT_DIR`, `ENV_STORE`.

---

## Проверка после установки

```bash
docker logs remnanode --tail 120                              # логи ноды
docker exec -it remnanode tail -f /var/log/xray/current       # логи Xray
systemctl status caddy --no-pager                             # статус Caddy
ss -lntup | grep -E ':443|:10443|:10444|:10445'               # слушатели
ufw status numbered                                           # правила firewall
```

Проверка SNI-роутинга вручную:

```bash
echo | openssl s_client -connect 127.0.0.1:443 -servername www.google.com -brief
```

---

## Диагностика

| Симптом | Причина / решение |
|---------|-------------------|
| Сертификаты не выпускаются | A-записи `<prefix>2/3` не указывают на ноду, либо `80/tcp` занят. Проверьте `dig`, освободите порт 80. |
| `UDP/443 не слушается` | В панели у Hysteria2-инбаунда нет привязанных юзеров, либо инбаунд не на `443/udp`. |
| Caddy не поднимается | `journalctl -u caddy -n 50` — обычно опечатка в SNI или конфликт порта 443 с host-процессом. |
| Нода `offline` в панели | API-порт закрыт для IP панели, неверный `SECRET_KEY`, либо `PANEL_IP` в ufw не совпадает. |
| BBR не активировался | Старое ядро или OpenVZ. Нужно ядро ≥ 4.9 и `modprobe tcp_bbr`. |

Полный лог каждой сессии: `/var/log/remnanode-setup-<дата>.log`.

---

## Безопасность

- `.env` с `SECRET_KEY` создаётся с правами `0600`.
- Приватные ключи сертификатов — `0600`, в контейнер монтируются **read-only**.
- API-порт ноды доступен только с IP панели (правило ufw `allow from <PANEL_IP>`).
- `--no-reset-firewall` сохраняет существующие правила ufw, если сервер не «чистый».

---

## Лицензия

MIT — см. [LICENSE](LICENSE).