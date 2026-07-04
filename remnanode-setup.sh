#!/usr/bin/env bash
set -Eeuo pipefail

BUILD_COMPOSE=1
MANAGE_FIREWALL=1
RESET_FIREWALL=1
FORCE_DNS=0
ASSUME_YES="${ASSUME_YES:-0}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"
SSH_PORT_OVERRIDE=""
NODE_DIR="${NODE_DIR:-/opt/remnanode}"
CERT_DIR="${CERT_DIR:-/etc/remna-certs}"
ENV_STORE="${ENV_STORE:-/root/remnanode.env}"
NODE_IMAGE="${NODE_IMAGE:-remnawave/node:latest}"
LOG_DIR="/var/log"
LOG_FILE="${LOG_DIR}/remnanode-setup-$(date +%F-%H%M%S).log"

usage() {
  cat <<'USAGE'
remnanode-setup.sh — установка ноды Remnawave (VLESS + Trojan + Hysteria2 за Caddy L4)

Использование:
  bash remnanode-setup.sh [флаги]

Флаги:
  --no-compose          не трогать docker-compose.yml (только .env + up -d)
  --no-firewall         не настраивать ufw
  --no-reset-firewall   не делать 'ufw reset' (сохранить существующие правила)
  --force-dns           не прерываться при несовпадении DNS
  --ssh-port N          явно указать SSH-порт для правила ufw
  --node-image REF      образ ноды (по умолчанию remnawave/node:latest)
  -y | --yes            авто-подтверждение всех «y/n» вопросов
  --non-interactive     не задавать вопросы: все значения из env/дефолтов
  -h | --help           показать эту справку

Переменные окружения (для --non-interactive / CI):
  BASE_DOMAIN, PREFIX, VISION_SNI, XHTTP_SNI, XHTTP_PATH,
  PANEL_IP, NODE_API_PORT, SECRET_KEY, NODE_IMAGE
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-compose)  BUILD_COMPOSE=0 ;;
    --no-firewall) MANAGE_FIREWALL=0 ;;
    --no-reset-firewall) RESET_FIREWALL=0 ;;
    --force-dns)   FORCE_DNS=1 ;;
    -y|--yes)      ASSUME_YES=1 ;;
    --non-interactive) NONINTERACTIVE=1; ASSUME_YES=1 ;;
    --ssh-port)
      SSH_PORT_OVERRIDE="${2:-}"
      [[ "$SSH_PORT_OVERRIDE" =~ ^[0-9]+$ ]] || { echo "--ssh-port требует число" >&2; exit 2; }
      shift ;;
    --node-image)
      NODE_IMAGE="${2:-}"
      [[ -n "$NODE_IMAGE" ]] || { echo "--node-image требует значение" >&2; exit 2; }
      shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Неизвестный аргумент: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

if [[ -t 1 || "${FORCE_COLOR:-0}" == 1 ]]; then
  C_RST=$'\033[0m';  C_B=$'\033[1m';   C_DIM=$'\033[2m'
  C_RED=$'\033[38;5;203m'; C_GRN=$'\033[38;5;114m'; C_YLW=$'\033[38;5;221m'
  C_BLU=$'\033[38;5;75m';  C_CYN=$'\033[38;5;80m';  C_MAG=$'\033[38;5;177m'
  C_GRY=$'\033[38;5;245m'; C_WHT=$'\033[38;5;255m'
else
  C_RST=; C_B=; C_DIM=; C_RED=; C_GRN=; C_YLW=; C_BLU=; C_CYN=; C_MAG=; C_GRY=; C_WHT=
fi

RULE='────────────────────────────────────────────────────────────────'
STEP_TOTAL=10

hr()   { printf '%s%s%s\n' "$C_DIM$C_GRY" "$RULE" "$C_RST"; }
log()  { printf ' %s➜%s %s\n'  "$C_BLU$C_B" "$C_RST" "$*"; }
ok()   { printf ' %s✔%s %s\n'  "$C_GRN$C_B" "$C_RST" "$*"; }
warn() { printf ' %s▲%s %s\n'  "$C_YLW$C_B" "$C_RST" "$*"; }
note() { printf '   %s%s%s\n'  "$C_DIM$C_GRY" "$*" "$C_RST"; }
die()  { printf ' %s✖%s %s\n'  "$C_RED$C_B" "$C_RST" "$*" >&2; exit 1; }

step() {
  local cur="$1" title="$2"
  printf '\n%s%s┏━ %s[ %02d / %02d ]%s %s%s%s%s\n' \
    "$C_B" "$C_CYN" "$C_RST$C_B$C_YLW" "$cur" "$STEP_TOTAL" \
    "$C_RST" "$C_B$C_CYN" "$title" "$C_RST" ""
  printf '%s%s┗%s%s%s\n' "$C_B" "$C_CYN" "$C_RST" "$C_DIM$C_GRY" "$RULE${C_RST}"
}

banner() {
  local L="$C_B$C_WHT" T="$C_B$C_MAG" D="$C_DIM$C_GRY" A="$C_B$C_CYN" S="$C_DIM$C_GRY" R="$C_RST"
  printf '%s\n' \
    "${D}╭──────────────────────────────────────────────────────────────╮${R}" \
    "${D}│${R}                                                              ${D}│${R}" \
    "${D}│${R}  ${L}▄█▀▄ ${R}  ${T}██╗      █████╗ ████████╗███████╗██╗  ██╗${R}            ${D}│${R}" \
    "${D}│${R}  ${L}▀ █  ${R}  ${T}██║     ██╔══██╗╚══██╔══╝██╔════╝╚██╗██╔╝${R}            ${D}│${R}" \
    "${D}│${R}  ${L}  █  ${R}  ${T}██║     ███████║   ██║   █████╗   ╚███╔╝ ${R}            ${D}│${R}" \
    "${D}│${R}  ${L}  █▄▟${R}  ${T}██║     ██╔══██║   ██║   ██╔══╝   ██╔██╗ ${R}            ${D}│${R}" \
    "${D}│${R}  ${L}  ▀█▀${R}  ${T}███████╗██║  ██║   ██║   ███████╗██╔╝ ██╗${R}            ${D}│${R}" \
    "${D}│${R}  ${L}     ${R}  ${T}╚══════╝╚═╝  ╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝${R}            ${D}│${R}" \
    "${D}│${R}                                                              ${D}│${R}" \
    "${D}│${R}  ${A}REMNAWAVE NODE · VLESS · Trojan · Hysteria2 · Caddy L4${R}      ${D}│${R}" \
    "${D}│${R}  ${S}by Latex · github.com/1atex${R}                                 ${D}│${R}" \
    "${D}╰──────────────────────────────────────────────────────────────╯${R}"
}

kv() { printf '   %s%-14s%s %s%s%s\n' "$C_GRY" "$1" "$C_RST" "$C_B" "$2" "$C_RST"; }

retry() {
  local -i tries="$1" delay="$2"; shift 2
  local -i n=1
  until "$@"; do
    if (( n >= tries )); then
      warn "Команда так и не удалась после ${tries} попыток: $*"
      return 1
    fi
    warn "Попытка ${n}/${tries} не удалась, повтор через ${delay}s: $*"
    sleep "$delay"
    n=$((n + 1))
  done
}

have() { command -v "$1" >/dev/null 2>&1; }
require_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Запускать нужно от root (sudo -i)."; }

apt_wait() {
  local -i waited=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
     || fuser /var/lib/dpkg/lock          >/dev/null 2>&1 \
     || fuser /var/lib/apt/lists/lock     >/dev/null 2>&1; do
    if (( waited % 60 == 0 )); then
      warn "Ожидаю освобождения apt/dpkg lock (прошло ${waited}s)..."
    fi
    sleep 5
    waited=$((waited + 5))
  done
}
apt_get() { apt_wait; DEBIAN_FRONTEND=noninteractive apt-get "$@"; }

ask() {
  local __var="$1" __prompt="$2" __default="${3:-}" __input
  if [[ "$NONINTERACTIVE" == 1 ]]; then
    [[ -n "$__default" ]] || die "--non-interactive: нет значения для «$__prompt» (задайте через env)."
    printf -v "$__var" '%s' "$__default"
    note "(auto) $__prompt = $__default"
    return
  fi
  if [[ -n "$__default" ]]; then
    printf ' %s?%s %s %s[%s]%s: ' "$C_MAG$C_B" "$C_RST" "$__prompt" "$C_DIM$C_GRY" "$__default" "$C_RST" > /dev/tty
    IFS= read -r __input < /dev/tty || true
    __input="${__input:-$__default}"
  else
    __input=""
    while [[ -z "$__input" ]]; do
      printf ' %s?%s %s: ' "$C_MAG$C_B" "$C_RST" "$__prompt" > /dev/tty
      IFS= read -r __input < /dev/tty || true
    done
  fi
  printf -v "$__var" '%s' "$__input"
}

# confirm "вопрос" "дефолт(y/n)" -> 0 если да, 1 если нет; уважает --yes/--non-interactive
confirm() {
  local __prompt="$1" __default="${2:-n}" __ans
  if [[ "$ASSUME_YES" == 1 ]]; then
    note "(auto-yes) $__prompt"
    return 0
  fi
  ask __ans "$__prompt (y/n)" "$__default"
  [[ "${__ans,,}" == y* ]]
}

detect_ssh_port() {
  local port=""
  if have sshd; then
    port="$(sshd -T 2>/dev/null | awk 'tolower($1)=="port"{print $2; exit}' || true)"
  fi
  if [[ ! "$port" =~ ^[0-9]+$ ]]; then
    port="$(awk 'tolower($1)=="port" && $2 ~ /^[0-9]+$/ {print $2; exit}' \
            /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true)"
  fi
  if [[ ! "$port" =~ ^[0-9]+$ && -n "${SSH_CONNECTION:-}" ]]; then
    port="$(awk '{print $4}' <<<"$SSH_CONNECTION" 2>/dev/null || true)"
  fi
  [[ "$port" =~ ^[0-9]+$ ]] || port=22
  printf '%s' "$port"
}

require_root

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

on_err() {
  local ec=$? line=$1 cmd=$2
  printf '\n %s✖ НЕПРЕДВИДЕННЫЙ СБОЙ%s код=%s строка=%s\n   %s%s%s\n' \
    "$C_RED$C_B" "$C_RST" "$ec" "$line" "$C_DIM$C_GRY" "$cmd" "$C_RST" >&2
  printf '   Полный лог: %s\n' "$LOG_FILE" >&2
  exit "$ec"
}
trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR

echo
banner
note "Лог сессии: $LOG_FILE"

step 0 "Preflight — ОС, ядро, ресурсы"

if [[ -r /etc/os-release ]]; then
  . /etc/os-release
else
  die "Не найден /etc/os-release."
fi
case "${ID:-}" in
  debian|ubuntu) ok "ОС: ${PRETTY_NAME:-$ID}" ;;
  *) die "Поддерживаются только Debian/Ubuntu (обнаружено: ${ID:-неизвестно})." ;;
esac

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64|aarch64|arm64) ok "Архитектура: $ARCH" ;;
  *) die "Неподдерживаемая архитектура: $ARCH." ;;
esac

KREL="$(uname -r)"
KMAJ="${KREL%%.*}"
KMIN="$(printf '%s' "$KREL" | cut -d. -f2)"
[[ "$KMAJ" =~ ^[0-9]+$ ]] || KMAJ=0
[[ "$KMIN" =~ ^[0-9]+$ ]] || KMIN=0
if (( KMAJ > 4 || (KMAJ == 4 && KMIN >= 9) )); then
  ok "Ядро: $KREL (BBR поддерживается)"
else
  warn "Ядро $KREL старое — BBR может быть недоступен."
fi

MEM_MB="$(awk '/MemTotal/ {printf "%d", $2/1024; exit}' /proc/meminfo 2>/dev/null || echo 0)"
[[ "$MEM_MB" =~ ^[0-9]+$ ]] || MEM_MB=0
if (( MEM_MB < 900 )); then
  warn "RAM ${MEM_MB}MB — маловато, сборка caddy-l4 может свопиться."
else
  ok "RAM: ${MEM_MB}MB"
fi
DISK_MB="$(df -Pm / | awk 'NR==2{print $4}' 2>/dev/null || echo 0)"
[[ "$DISK_MB" =~ ^[0-9]+$ ]] || DISK_MB=0
if (( DISK_MB < 3000 )); then
  warn "Свободно ${DISK_MB}MB на / — Go+Docker могут не влезть."
else
  ok "Свободно на /: ${DISK_MB}MB"
fi

log "Устанавливаю базовые утилиты (curl, ca-certificates, dnsutils)"
retry 3 5 apt_get update -y || warn "apt-get update завершился с ошибкой — продолжаю с текущими списками."
retry 3 5 apt_get install -y curl ca-certificates dnsutils \
  || warn "Не удалось установить базовые утилиты — некоторые проверки будут ограничены."

step 1 "Переменные окружения"

if [[ -f "$ENV_STORE" ]]; then
  if confirm "Найден $ENV_STORE. Загрузить сохранённые переменные?" "y"; then
    source "$ENV_STORE" || warn "Не удалось прочитать $ENV_STORE — продолжаю без него."
    ok "Переменные загружены из $ENV_STORE"
  fi
fi

SERVER_IP=""
if have curl; then
  SERVER_IP="$(curl -4 -sS --max-time 10 https://ifconfig.me 2>/dev/null || true)"
  [[ -n "$SERVER_IP" ]] || SERVER_IP="$(curl -4 -sS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
fi
if [[ "$SERVER_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
  ok "Публичный IPv4: $SERVER_IP"
else
  SERVER_IP=""
  warn "Не удалось определить IP (проверка DNS будет мягкой)."
fi

ask BASE_DOMAIN "Базовый домен (напр. example.com)" "${BASE_DOMAIN:-}"
ask PREFIX      "Префикс поддомена (напр. usa)"      "${PREFIX:-usa}"
VLESS_HOST="${PREFIX}1.${BASE_DOMAIN}"
TROJAN_HOST="${PREFIX}2.${BASE_DOMAIN}"
HY_HOST="${PREFIX}3.${BASE_DOMAIN}"
ok "Домены: $VLESS_HOST / $TROJAN_HOST / $HY_HOST"

ACME_EMAIL="admin@${BASE_DOMAIN}"
ok "Email для Let's Encrypt: $ACME_EMAIL"

ask VISION_SNI "Маскировочный SNI для Vision/Reality" "${VISION_SNI:-www.google.com}"
ask XHTTP_SNI  "Маскировочный SNI для XHTTP"          "${XHTTP_SNI:-www.gstatic.com}"
ask XHTTP_PATH "Путь XHTTP"                           "${XHTTP_PATH:-/api/v3/sync/r1}"
ask PANEL_IP   "IP панели Remnawave"                  "${PANEL_IP:-}"
ask NODE_API_PORT "Порт ноды для связи с панелью"     "${NODE_API_PORT:-2222}"

[[ "$BASE_DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || die "Некорректный домен: $BASE_DOMAIN"
[[ "$PREFIX" =~ ^[a-zA-Z0-9-]+$ ]]                      || die "Некорректный префикс: $PREFIX"
[[ "$PANEL_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]     || die "Некорректный IP панели: $PANEL_IP"
{ [[ "$NODE_API_PORT" =~ ^[0-9]+$ ]] && (( NODE_API_PORT >= 1 && NODE_API_PORT <= 65535 )); } \
  || die "Некорректный порт ноды: $NODE_API_PORT"

export SERVER_IP BASE_DOMAIN PREFIX VLESS_HOST TROJAN_HOST HY_HOST ACME_EMAIL \
       VISION_SNI XHTTP_SNI XHTTP_PATH PANEL_IP NODE_API_PORT

( umask 077
  cat > "$ENV_STORE" <<EOF
export SERVER_IP="$SERVER_IP"
export BASE_DOMAIN="$BASE_DOMAIN"
export PREFIX="$PREFIX"
export VLESS_HOST="$VLESS_HOST"
export TROJAN_HOST="$TROJAN_HOST"
export HY_HOST="$HY_HOST"
export ACME_EMAIL="$ACME_EMAIL"
export VISION_SNI="$VISION_SNI"
export XHTTP_SNI="$XHTTP_SNI"
export XHTTP_PATH="$XHTTP_PATH"
export PANEL_IP="$PANEL_IP"
export NODE_API_PORT="$NODE_API_PORT"
EOF
)
grep -q "source $ENV_STORE" /root/.bashrc 2>/dev/null \
  || echo "[ -f $ENV_STORE ] && source $ENV_STORE" >> /root/.bashrc
ok "Переменные сохранены в $ENV_STORE (0600, подхват в .bashrc)"

echo
hr
kv "SERVER_IP"     "$SERVER_IP"
kv "VLESS"         "$VLESS_HOST"
kv "TROJAN"        "$TROJAN_HOST"
kv "HYSTERIA2"     "$HY_HOST"
kv "VISION_SNI"    "$VISION_SNI"
kv "XHTTP_SNI"     "$XHTTP_SNI"
kv "PANEL_IP"      "$PANEL_IP"
kv "NODE_API_PORT" "$NODE_API_PORT"
hr
echo
confirm "Всё верно, продолжаем?" "y" || die "Отменено пользователем."

step 2 "Проверка DNS и SNI"
DNS_OK=1
for d in "$VLESS_HOST" "$TROJAN_HOST" "$HY_HOST"; do
  resolved="$(dig +short "$d" A 2>/dev/null | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/{print; exit}' || true)"
  if [[ -z "$SERVER_IP" ]]; then
    note "$d -> ${resolved:-<нет A-записи>}"
  elif [[ "$resolved" == "$SERVER_IP" ]]; then
    ok "$d -> $resolved"
  else
    warn "$d -> ${resolved:-<нет A-записи>} (ожидался $SERVER_IP)"; DNS_OK=0
  fi
done
if [[ "$DNS_OK" -eq 0 && "$FORCE_DNS" -eq 0 ]]; then
  confirm "DNS не совпадает — сертификаты могут не выпуститься. Продолжить?" "n" \
    || die "Прервано из-за DNS. Поправьте A-записи или запустите с --force-dns."
fi
for d in "$VISION_SNI" "$XHTTP_SNI"; do
  proto="$(echo | timeout 8 openssl s_client -connect "$d:443" -servername "$d" -alpn h2 -tls1_3 -brief 2>&1 \
           | grep -Ei 'Protocol|ALPN' | tr '\n' ' ' || true)"
  [[ -n "$proto" ]] && ok "SNI $d: $proto" || warn "SNI $d: не удалось проверить TLS1.3/h2"
done

step 3 "Базовые пакеты и Docker"
retry 3 5 apt_get update -y || warn "apt-get update с ошибкой — продолжаю."
retry 3 5 apt_get install -y curl gnupg debian-keyring debian-archive-keyring apt-transport-https \
                   ca-certificates lsb-release git jq unzip nano htop socat cron openssl \
                   ufw psmisc \
  || die "Не удалось установить базовые пакеты."

if ! have docker; then
  retry 3 10 bash -c 'curl -fsSL https://get.docker.com | sh' \
    || die "Не удалось установить Docker через get.docker.com."
else
  ok "Docker уже установлен"
fi

mkdir -p /etc/docker
if [[ ! -f /etc/docker/daemon.json ]]; then
  cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "5" },
  "live-restore": true
}
EOF
  ok "Настроена ротация логов Docker (/etc/docker/daemon.json)"
else
  warn "/etc/docker/daemon.json уже есть — не перезаписываю (проверьте log-opts вручную)."
fi
systemctl enable --now docker || die "Не удалось запустить docker.service."
systemctl restart docker      || die "Не удалось перезапустить docker.service."
docker --version || true
docker compose version >/dev/null 2>&1 || die "docker compose plugin недоступен."
ok "Docker готов"

if [[ "$MANAGE_FIREWALL" -eq 1 ]]; then
  step 4 "Firewall (ufw)"
  if [[ -n "$SSH_PORT_OVERRIDE" ]]; then
    SSH_PORT="$SSH_PORT_OVERRIDE"
  else
    SSH_PORT="$(detect_ssh_port)"
  fi
  ok "SSH-порт для ufw: $SSH_PORT (переопределить: --ssh-port N)"

  if [[ "$RESET_FIREWALL" -eq 1 ]]; then
    warn "ufw reset: текущие правила будут стёрты (--no-reset-firewall чтобы сохранить)."
    ufw --force reset        >/dev/null || die "ufw reset не удался."
  else
    note "ufw reset пропущен — правила добавляются поверх существующих."
  fi
  ufw default deny incoming  >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow "${SSH_PORT}/tcp" comment 'SSH'                        >/dev/null
  ufw allow 443/tcp           comment 'VLESS/Trojan via Caddy L4'  >/dev/null
  ufw allow 443/udp           comment 'Hysteria2 QUIC'             >/dev/null
  ufw allow 80/tcp            comment 'acme.sh standalone'         >/dev/null
  ufw allow from "$PANEL_IP" to any port "$NODE_API_PORT" proto tcp comment 'Remnawave panel -> node' >/dev/null
  ufw --force enable >/dev/null || die "Не удалось включить ufw."
  ok "ufw включён. API-порт $NODE_API_PORT доступен только с $PANEL_IP."
  ufw status numbered | sed 's/^/   /' || true
else
  step 4 "Firewall (пропущен)"
  warn "--no-firewall: убедитесь, что 443 tcp/udp, 80/tcp открыты, а $NODE_API_PORT доступен только панели."
fi

step 5 "Сборка Caddy с модулем layer4"
if ! caddy list-modules 2>/dev/null | grep -qE 'layer4'; then
  if [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
    retry 3 5 bash -c "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg" \
      || die "Не удалось получить GPG-ключ Caddy."
  fi
  if [[ ! -f /etc/apt/sources.list.d/caddy-stable.list ]]; then
    retry 3 5 bash -c "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      > /etc/apt/sources.list.d/caddy-stable.list" \
      || die "Не удалось получить apt-репозиторий Caddy."
  fi
  retry 3 5 apt_get update -y || warn "apt-get update (caddy repo) с ошибкой — продолжаю."
  apt-mark unhold caddy >/dev/null 2>&1 || true
  retry 3 5 apt_get install -y caddy golang-go build-essential libcap2-bin \
    || die "Не удалось установить caddy/golang/build-essential."

  retry 3 10 env GOBIN=/usr/local/bin go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest \
    || die "Не удалось установить xcaddy."
  mkdir -p /root/build-caddy-l4
  ( cd /root/build-caddy-l4 && retry 2 10 xcaddy build --with github.com/mholt/caddy-l4 --output ./caddy ) \
    || die "xcaddy build не удался."
  /root/build-caddy-l4/caddy list-modules 2>/dev/null | grep -qE 'layer4' \
    || die "В собранном бинаре нет модулей layer4."

  systemctl stop caddy 2>/dev/null || true
  cp -a /usr/bin/caddy "/usr/bin/caddy.stock-$(date +%F-%H%M%S)" 2>/dev/null || true
  install -m 755 /root/build-caddy-l4/caddy /usr/bin/caddy
  setcap cap_net_bind_service=+ep /usr/bin/caddy || warn "setcap не удался — Caddy может не занять :80/:443 без root."
  apt-mark hold caddy >/dev/null 2>&1 || true
  systemctl enable caddy >/dev/null 2>&1 || true
  L4_COUNT="$(caddy list-modules 2>/dev/null | grep -c layer4 || true)"
  ok "Кастомный Caddy собран (${L4_COUNT:-0} L4-модулей)"
else
  ok "Caddy c layer4 уже установлен — сборку пропускаю"
fi
caddy version || true

step 6 "Caddyfile — L4-роутинг по SNI"
cp -a /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.backup-$(date +%F-%H%M%S)" 2>/dev/null || true
cat > /etc/caddy/Caddyfile <<EOF
{
  layer4 {
    :443 {
      @vision tls sni $VISION_SNI
      route @vision {
        proxy 127.0.0.1:10443
      }
      @xhttp tls sni $XHTTP_SNI
      route @xhttp {
        proxy 127.0.0.1:10444
      }
      @trojan tls sni $TROJAN_HOST
      route @trojan {
        proxy 127.0.0.1:10445
      }
      route {
        proxy $VISION_SNI:443
      }
    }
  }
}
EOF
caddy fmt --overwrite /etc/caddy/Caddyfile || warn "caddy fmt не удался — продолжаю."
caddy validate --config /etc/caddy/Caddyfile || die "Caddyfile невалиден — исправьте SNI/синтаксис."
systemctl restart caddy || die "Не удалось перезапустить Caddy."
sleep 1
if systemctl is-active --quiet caddy; then
  ok "Caddy запущен (restart)"
else
  die "Caddy не поднялся. journalctl -u caddy -n 50"
fi

step 7 "Сертификаты acme.sh (Trojan + Hysteria2)"
if ss -lntup 2>/dev/null | grep -q ':80 '; then
  warn "Порт 80 занят — acme.sh standalone может не выпустить сертификаты:"
  ss -lntup 2>/dev/null | grep ':80 ' | sed 's/^/   /' || true
fi
if [[ ! -x /root/.acme.sh/acme.sh ]]; then
  retry 3 10 bash -c "curl -fsSL https://get.acme.sh | sh -s email='$ACME_EMAIL'" \
    || die "Не удалось установить acme.sh."
fi
ACME=/root/.acme.sh/acme.sh
[[ -x "$ACME" ]] || die "acme.sh не найден по пути $ACME."
"$ACME" --upgrade --auto-upgrade >/dev/null 2>&1 || true
"$ACME" --set-default-ca --server letsencrypt >/dev/null 2>&1 || warn "Не удалось выставить CA по умолчанию."

issue_cert() {
  local d="$1"
  if "$ACME" --list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$d"; then
    ok "Сертификат для $d уже выпущен — пропускаю issue"
  else
    "$ACME" --issue --standalone -d "$d" --keylength ec-256 \
      || warn "Не удалось выпустить сертификат для $d (проверьте DNS/порт 80)."
  fi
}
issue_cert "$TROJAN_HOST"
issue_cert "$HY_HOST"

mkdir -p "$CERT_DIR/$TROJAN_HOST" "$CERT_DIR/$HY_HOST"
"$ACME" --install-cert -d "$TROJAN_HOST" --ecc \
  --key-file       "$CERT_DIR/$TROJAN_HOST/key.pem" \
  --fullchain-file "$CERT_DIR/$TROJAN_HOST/fullchain.pem" \
  --reloadcmd "docker restart remnanode >/dev/null 2>&1 || true" \
  || warn "install-cert для $TROJAN_HOST не удался (сертификат мог не выпуститься)."
"$ACME" --install-cert -d "$HY_HOST" --ecc \
  --key-file       "$CERT_DIR/$HY_HOST/key.pem" \
  --fullchain-file "$CERT_DIR/$HY_HOST/fullchain.pem" \
  --reloadcmd "docker restart remnanode >/dev/null 2>&1 || true" \
  || warn "install-cert для $HY_HOST не удался (сертификат мог не выпуститься)."

chown -R root:root "$CERT_DIR"
find "$CERT_DIR" -type d -exec chmod 755 {} \; || true
find "$CERT_DIR" -type f -name 'key.pem'       -exec chmod 600 {} \; || true
find "$CERT_DIR" -type f -name 'fullchain.pem' -exec chmod 644 {} \; || true
ok "Сертификаты установлены в $CERT_DIR (автопродление — таймер/cron acme.sh)"

step 8 "sysctl-тюнинг (BBR/fq, UDP-буферы, fd-лимиты)"
cat > /etc/sysctl.d/99-remnanode.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.netdev_max_backlog = 32768
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
fs.file-max = 1048576
fs.nr_open = 1048576
EOF
modprobe tcp_bbr 2>/dev/null || true
grep -q '^tcp_bbr' /etc/modules-load.d/bbr.conf 2>/dev/null || echo tcp_bbr > /etc/modules-load.d/bbr.conf
sysctl --system >/dev/null 2>&1 || warn "sysctl --system вернул ошибку по части ключей (не критично)."

cat > /etc/security/limits.d/99-remnanode.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
qd="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
rbuf="$(sysctl -n net.core.rmem_max 2>/dev/null || echo '?')"
if [[ "$cc" == "bbr" ]]; then
  ok "congestion=$cc qdisc=$qd, UDP buf=$rbuf"
else
  warn "BBR не активировался (сейчас: $cc). Возможно нужно новое ядро/перезапуск."
fi

step 9 "Нода Remnawave (compose)"
mkdir -p "$NODE_DIR"
echo
note "Создайте ноду в панели (Nodes -> Add) с IP $SERVER_IP и портом $NODE_API_PORT."
note "Панель выдаст SECRET_KEY (публичный ключ ноды). Вставьте его целиком."
note "Можно как чистое значение (eyJ...), так и строку 'SECRET_KEY=...'."
echo
ask SECRET_RAW "SECRET_KEY из панели" "${SECRET_KEY:-}"

SECRET_VALUE="$SECRET_RAW"
SECRET_VALUE="${SECRET_VALUE#SECRET_KEY=}"
SECRET_VALUE="${SECRET_VALUE#\"}"; SECRET_VALUE="${SECRET_VALUE%\"}"
SECRET_VALUE="${SECRET_VALUE#\'}"; SECRET_VALUE="${SECRET_VALUE%\'}"
SECRET_VALUE="$(printf '%s' "$SECRET_VALUE" | tr -d '[:space:]')"
[[ -n "$SECRET_VALUE" ]] || die "Пустой SECRET_KEY."

if [[ "$BUILD_COMPOSE" -eq 1 ]]; then
  ( umask 077
    cat > "$NODE_DIR/.env" <<EOF
NODE_PORT=$NODE_API_PORT
SECRET_KEY=$SECRET_VALUE
NODE_IMAGE=$NODE_IMAGE
EOF
  )
  cat > "$NODE_DIR/docker-compose.yml" <<'EOF'
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: ${NODE_IMAGE:-remnawave/node:latest}
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "5"
    env_file:
      - .env
    environment:
      - NODE_PORT=${NODE_PORT}
      - SECRET_KEY=${SECRET_KEY}
    volumes:
      - /etc/remna-certs:/etc/remna-certs:ro
EOF
  ok "Записаны $NODE_DIR/.env (0600) и docker-compose.yml"
else
  [[ -f "$NODE_DIR/docker-compose.yml" ]] || die "--no-compose, но $NODE_DIR/docker-compose.yml отсутствует."
  ( umask 077
    {
      echo "NODE_PORT=$NODE_API_PORT"
      echo "SECRET_KEY=$SECRET_VALUE"
      echo "NODE_IMAGE=$NODE_IMAGE"
    } > "$NODE_DIR/.env"
  )
  ok "Обновлён $NODE_DIR/.env (compose оставлен как есть)"
fi

( cd "$NODE_DIR" && retry 3 10 docker compose pull ) || die "docker compose pull не удался."
( cd "$NODE_DIR" && docker compose up -d --force-recreate ) || die "docker compose up не удался."

log "Жду готовности ноды (до 30s)..."
node_ready=0
for _ in $(seq 1 15); do
  state="$(docker inspect -f '{{.State.Status}}' remnanode 2>/dev/null || echo missing)"
  if [[ "$state" == running ]] && ss -lntp 2>/dev/null | grep -q ":${NODE_API_PORT} "; then
    node_ready=1; break
  fi
  sleep 2
done
if [[ "$node_ready" -eq 1 ]]; then
  ok "Нода запущена и слушает API-порт $NODE_API_PORT"
else
  warn "Нода не подтвердила готовность за 30s (state=${state:-?}). Проверьте: docker logs remnanode --tail 120"
fi
docker ps --filter name=remnanode --format 'table {{.Names}}\t{{.Status}}' | sed 's/^/   /' || true
docker exec remnanode sh -lc \
  'find /etc/remna-certs -type f \( -name "key.pem" -o -name "fullchain.pem" \) -printf "%M %u:%g %p\n" | sort' \
  2>/dev/null | sed 's/^/   /' || warn "Не удалось прочитать сертификаты внутри контейнера (docker logs remnanode)."
ok "Контейнер remnanode запущен"

step 10 "Проверка слушателей и маршрутизации"
printf '   %s%sTCP listeners%s\n' "$C_B" "$C_MAG" "$C_RST"
ss -lntup 2>/dev/null | grep -E ':443|:10443|:10444|:10445|:'"$NODE_API_PORT" | sed 's/^/     /' || true
printf '   %s%sUDP listeners (Hysteria2)%s\n' "$C_B" "$C_MAG" "$C_RST"
ss -lnuap 2>/dev/null | grep ':443' | sed 's/^/     /' || warn "UDP/443 не слушается — проверьте Hysteria2 inbound в панели."
for pair in "Vision:$VISION_SNI" "XHTTP:$XHTTP_SNI" "Trojan:$TROJAN_HOST"; do
  name="${pair%%:*}"; sni="${pair#*:}"
  printf '   %s%s%s (%s)%s\n' "$C_B" "$C_MAG" "$name" "$sni" "$C_RST"
  echo | timeout 8 openssl s_client -connect 127.0.0.1:443 -servername "$sni" -brief 2>&1 | head -6 | sed 's/^/     /' || true
done

echo
printf '%s%s╭──────────────────────────────────────────────────────────────╮%s\n' "$C_B" "$C_GRN" "$C_RST"
printf '%s%s│%s  %s✔ ГОТОВО%s  Проверьте статус ноды в панели — должна быть online   %s%s│%s\n' \
  "$C_B" "$C_GRN" "$C_RST" "$C_B$C_GRN" "$C_RST" "$C_B$C_GRN" "" "$C_RST"
printf '%s%s╰──────────────────────────────────────────────────────────────╯%s\n' "$C_B" "$C_GRN" "$C_RST"
echo
printf '   %s%sКонфигурация нод-инбаундов (сверьте в панели)%s\n' "$C_B" "$C_MAG" "$C_RST"
kv "Vision/Reality" "SNI $VISION_SNI  →  127.0.0.1:10443  (dest/self-steal: $VISION_SNI:443)"
kv "XHTTP"          "SNI $XHTTP_SNI  path $XHTTP_PATH  →  127.0.0.1:10444"
kv "Trojan (TLS)"   "SNI $TROJAN_HOST  →  127.0.0.1:10445  (cert $CERT_DIR/$TROJAN_HOST)"
kv "Hysteria2"      "UDP/443 напрямую  (cert $CERT_DIR/$HY_HOST)"
kv "Node API"       "$SERVER_IP:$NODE_API_PORT  (только с панели $PANEL_IP)"
kv "Образ ноды"     "$NODE_IMAGE"
echo
kv "Лог установки"   "$LOG_FILE"
kv "Логи ноды"       "docker logs remnanode --tail 120"
kv "Логи Xray"      "docker exec -it remnanode tail -n +1 -f /var/log/xray/current"
kv "Статус Caddy"    "systemctl status caddy --no-pager"
kv "Firewall"        "ufw status numbered"
echo