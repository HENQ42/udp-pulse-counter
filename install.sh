#!/usr/bin/env bash
# install.sh
#
# Instala o contador-udp-zabbix como servico systemd no Ubuntu.
#
# - Requer Go ja instalado (nao tenta instalar).
# - Requer root (usa systemctl, escreve em /opt e /etc/systemd/system).
# - Remove APENAS arquivos do proprio projeto (caminhos fixos abaixo).
#   Nao toca em nada mais do sistema.
# - Idempotente: rodar de novo apenas atualiza.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuracao
# ---------------------------------------------------------------------------
readonly APP_NAME="contador-udp"
readonly BIN_NAME="contador_udp_zabbix"
readonly SRC_FILE="contador_udp_zabbix.go"

readonly INSTALL_DIR="/opt/${APP_NAME}"
readonly INSTALL_BIN="${INSTALL_DIR}/${BIN_NAME}"
readonly UNIT_FILE="/etc/systemd/system/${APP_NAME}.service"
readonly SYSCTL_FILE="/etc/sysctl.d/99-${APP_NAME}.conf"
# Diretorios/arquivos de instalacoes antigas (limpeza apenas)
readonly LEGACY_TOKEN_DIR="/etc/${APP_NAME}"
readonly LEGACY_TOKEN_FILE="${LEGACY_TOKEN_DIR}/token.env"

# Bind HTTP: localhost-only por padrao (Zabbix no proprio servidor).
readonly DEFAULT_HTTP_HOST="127.0.0.1"

# Defaults da aplicacao
readonly DEFAULT_PORT_RANGE="5000-5049"
readonly DEFAULT_HTTP_PORT="23187"
readonly DEFAULT_BUCKET_SECONDS="900"
readonly DEFAULT_ACTIVE="high"
readonly DEFAULT_PREFIX="cam"

# Caminho absoluto da raiz do projeto (onde este script vive)
readonly PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<EOF
Uso: sudo $0 [-h|--help]

Instala/atualiza o ${APP_NAME} como servico systemd.
HTTP escuta apenas em 127.0.0.1 — sem necessidade de token.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0;;
            *) die "argumento desconhecido: $1 (use --help)";;
        esac
    done
}

# ---------------------------------------------------------------------------
# Helpers de log
# ---------------------------------------------------------------------------
c_red()    { printf '\033[31m%s\033[0m' "$*"; }
c_green()  { printf '\033[32m%s\033[0m' "$*"; }
c_yellow() { printf '\033[33m%s\033[0m' "$*"; }
c_blue()   { printf '\033[34m%s\033[0m' "$*"; }

log()  { echo "[ $(c_blue   '..') ] $*"; }
ok()   { echo "[ $(c_green  'OK') ] $*"; }
warn() { echo "[ $(c_yellow 'WW') ] $*"; }
die()  { echo "[ $(c_red    'XX') ] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Pre-checks
# ---------------------------------------------------------------------------
require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "rode como root: sudo $0"
    fi
}

require_linux_ubuntu() {
    log "verificando SO..."
    [[ "$(uname -s)" == "Linux" ]] || die "este script e apenas para Linux"
    [[ -r /etc/os-release ]]       || die "/etc/os-release nao encontrado"

    # shellcheck disable=SC1091
    . /etc/os-release
    local id="${ID:-}" id_like="${ID_LIKE:-}"
    if [[ "${id}" != "ubuntu" && "${id}" != "debian" \
          && "${id_like}" != *"ubuntu"* && "${id_like}" != *"debian"* ]]; then
        die "distro nao suportada (esperado Ubuntu/Debian, achei: ${id})"
    fi
    ok "SO: ${PRETTY_NAME:-$id}"
}

require_paths_exist() {
    log "verificando estrutura de diretorios do sistema..."
    local p
    for p in /etc /etc/systemd/system /etc/sysctl.d /opt /var/log; do
        [[ -d "${p}" ]] || die "diretorio ausente: ${p}"
    done
    ok "estrutura de diretorios OK"
}

require_systemd() {
    command -v systemctl >/dev/null 2>&1 || die "systemctl nao encontrado"
    [[ -d /run/systemd/system ]] || die "este sistema nao parece estar rodando systemd"
    ok "systemd disponivel"
}

require_go() {
    if ! command -v go >/dev/null 2>&1; then
        # tenta descobrir em /usr/local/go/bin caso o PATH desta shell ainda nao tenha
        if [[ -x /usr/local/go/bin/go ]]; then
            export PATH="${PATH}:/usr/local/go/bin"
            warn "go encontrado em /usr/local/go/bin (adicionado ao PATH desta sessao)"
        else
            die "go nao encontrado. Instale o Go antes de rodar este script."
        fi
    fi
    ok "go: $(go version)"
}

require_source() {
    [[ -f "${PROJECT_DIR}/${SRC_FILE}" ]] \
        || die "nao encontrei ${SRC_FILE} em ${PROJECT_DIR}"
    ok "fonte encontrada: ${PROJECT_DIR}/${SRC_FILE}"
}

# ---------------------------------------------------------------------------
# Instalacao
# ---------------------------------------------------------------------------
stop_service_if_running() {
    if systemctl list-unit-files | grep -q "^${APP_NAME}\.service"; then
        if systemctl is-active --quiet "${APP_NAME}.service"; then
            log "parando servico em execucao..."
            systemctl stop "${APP_NAME}.service"
            ok "servico parado"
        fi
    fi
}

# Remove APENAS arquivos conhecidos do projeto.
# Nao usa rm -rf em diretorios pais nem em paths variaveis.
clean_previous_install() {
    log "limpando instalacao anterior (apenas arquivos deste projeto)..."

    local removed=0
    if [[ -f "${INSTALL_BIN}" ]]; then
        rm -f "${INSTALL_BIN}"
        warn "removido: ${INSTALL_BIN}"
        removed=1
    fi
    if [[ -d "${INSTALL_DIR}" ]]; then
        # So remove o diretorio se estiver vazio (seguranca contra apagar
        # arquivos colocados manualmente pelo operador).
        if [[ -z "$(ls -A "${INSTALL_DIR}")" ]]; then
            rmdir "${INSTALL_DIR}"
            warn "removido (vazio): ${INSTALL_DIR}"
            removed=1
        fi
    fi
    if [[ -f "${UNIT_FILE}" ]]; then
        rm -f "${UNIT_FILE}"
        warn "removido: ${UNIT_FILE}"
        removed=1
    fi
    if [[ -f "${SYSCTL_FILE}" ]]; then
        rm -f "${SYSCTL_FILE}"
        warn "removido: ${SYSCTL_FILE}"
        removed=1
    fi
    # Legado: instalacoes anteriores que usavam token.
    if [[ -f "${LEGACY_TOKEN_FILE}" ]]; then
        rm -f "${LEGACY_TOKEN_FILE}"
        warn "removido (legado): ${LEGACY_TOKEN_FILE}"
        removed=1
    fi
    if [[ -d "${LEGACY_TOKEN_DIR}" ]] && [[ -z "$(ls -A "${LEGACY_TOKEN_DIR}")" ]]; then
        rmdir "${LEGACY_TOKEN_DIR}"
        warn "removido (legado, vazio): ${LEGACY_TOKEN_DIR}"
        removed=1
    fi

    if [[ "${removed}" -eq 0 ]]; then
        ok "nada para limpar"
    else
        ok "limpeza concluida"
    fi
}

build_binary() {
    log "compilando ${BIN_NAME}..."
    (
        cd "${PROJECT_DIR}"
        CGO_ENABLED=0 go build -ldflags="-s -w" -o "${BIN_NAME}" "${SRC_FILE}"
    )
    [[ -x "${PROJECT_DIR}/${BIN_NAME}" ]] || die "binario nao gerado"
    ok "binario compilado: ${PROJECT_DIR}/${BIN_NAME}"
}

install_binary() {
    log "instalando binario em ${INSTALL_BIN}..."
    install -d -m 0755 "${INSTALL_DIR}"
    install -m 0755 -o root -g root "${PROJECT_DIR}/${BIN_NAME}" "${INSTALL_BIN}"
    ok "binario instalado"
}

install_sysctl() {
    log "configurando sysctl para reservar portas ${DEFAULT_PORT_RANGE}..."
    cat > "${SYSCTL_FILE}" <<EOF
# Reserva as portas usadas pelo ${APP_NAME} para que o kernel nao as
# entregue como ephemeral a outros processos.
net.ipv4.ip_local_reserved_ports = ${DEFAULT_PORT_RANGE//-/-}
EOF
    chmod 0644 "${SYSCTL_FILE}"
    sysctl --system >/dev/null
    ok "sysctl aplicado: $(cat /proc/sys/net/ipv4/ip_local_reserved_ports || true)"
}

install_unit() {
    log "criando unit do systemd em ${UNIT_FILE}..."
    cat > "${UNIT_FILE}" <<EOF
[Unit]
Description=Contador UDP -> Zabbix
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
ExecStart=${INSTALL_BIN} \\
  --port-range ${DEFAULT_PORT_RANGE} \\
  --counter-prefix ${DEFAULT_PREFIX} \\
  --http-host ${DEFAULT_HTTP_HOST} \\
  --http-port ${DEFAULT_HTTP_PORT} \\
  --bucket-seconds ${DEFAULT_BUCKET_SECONDS} \\
  --active ${DEFAULT_ACTIVE}
Restart=always
RestartSec=3
StartLimitIntervalSec=60
StartLimitBurst=10

# Hardening basico: nao precisa de privilegio elevado nem escrita em disco.
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "${UNIT_FILE}"
    ok "unit criada"
}

enable_and_start() {
    log "habilitando e iniciando servico..."
    systemctl daemon-reload
    systemctl enable "${APP_NAME}.service" >/dev/null
    systemctl restart "${APP_NAME}.service"
    sleep 1
    if systemctl is-active --quiet "${APP_NAME}.service"; then
        ok "servico ativo"
    else
        warn "servico nao subiu. Veja:  journalctl -u ${APP_NAME} -n 50"
        exit 1
    fi
}

print_summary() {
    echo
    ok "instalacao concluida"
    echo
    echo "  Binario        : ${INSTALL_BIN}"
    echo "  Unit           : ${UNIT_FILE}"
    echo "  Sysctl         : ${SYSCTL_FILE}"
    echo "  Range UDP      : ${DEFAULT_PORT_RANGE}"
    echo "  HTTP           : ${DEFAULT_HTTP_HOST}:${DEFAULT_HTTP_PORT} (localhost-only, sem auth)"
    echo "  Prefixo nomes  : ${DEFAULT_PREFIX} -> cam5000..cam5049"
    echo
    echo "Comandos uteis:"
    echo "  systemctl status ${APP_NAME}"
    echo "  journalctl -u ${APP_NAME} -f"
    echo "  curl http://127.0.0.1:${DEFAULT_HTTP_PORT}/health"
    echo "  curl http://127.0.0.1:${DEFAULT_HTTP_PORT}/cameras"
    echo
}

# ---------------------------------------------------------------------------
# Fluxo
# ---------------------------------------------------------------------------
main() {
    require_root
    require_linux_ubuntu
    require_paths_exist
    require_systemd
    require_go
    require_source

    stop_service_if_running
    clean_previous_install

    build_binary
    install_binary
    install_sysctl
    install_unit
    enable_and_start
    print_summary
}

parse_args "$@"
main
