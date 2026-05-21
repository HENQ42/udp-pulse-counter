#!/usr/bin/env bash
# install.sh
#
# Instala o contador-udp-zabbix como servico systemd.
# Distros suportadas: Ubuntu/Debian e Red Hat Enterprise Linux 9 (x86_64)
# e derivados (Rocky, AlmaLinux, CentOS Stream 9).
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
# Estado persistente: contagens monotonicas por camera.
# NAO e removido em reinstalacao para preservar historico.
readonly STATE_DIR="/var/lib/${APP_NAME}"
readonly STATE_FILE="${STATE_DIR}/state.json"
# Diretorios/arquivos de instalacoes antigas (limpeza apenas)
readonly LEGACY_TOKEN_DIR="/etc/${APP_NAME}"
readonly LEGACY_TOKEN_FILE="${LEGACY_TOKEN_DIR}/token.env"

# Bind HTTP: localhost-only por padrao (Zabbix no proprio servidor).
readonly DEFAULT_HTTP_HOST="127.0.0.1"

# Defaults da aplicacao
readonly DEFAULT_PORT_RANGE="5000-5249"
readonly DEFAULT_HTTP_PORT="23187"
readonly DEFAULT_ACTIVE="high"
readonly DEFAULT_PREFIX="cam"
readonly DEFAULT_PERSIST_INTERVAL="60s"

# Caminho absoluto da raiz do projeto (onde este script vive)
readonly PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Grupo do usuario "nobody". Em Debian/Ubuntu e "nogroup"; em RHEL e "nobody".
# Definido em runtime por detect_service_group().
SERVICE_USER="nobody"
SERVICE_GROUP=""

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

require_linux_supported() {
    log "verificando SO..."
    [[ "$(uname -s)" == "Linux" ]] || die "este script e apenas para Linux"
    [[ -r /etc/os-release ]]       || die "/etc/os-release nao encontrado"

    local arch
    arch="$(uname -m)"
    if [[ "${arch}" != "x86_64" && "${arch}" != "amd64" ]]; then
        die "arquitetura nao suportada: ${arch} (esperado x86_64)"
    fi

    # shellcheck disable=SC1091
    . /etc/os-release
    local id="${ID:-}" id_like="${ID_LIKE:-}"
    local supported=0

    # Debian / Ubuntu
    if [[ "${id}" == "ubuntu" || "${id}" == "debian" \
          || "${id_like}" == *"ubuntu"* || "${id_like}" == *"debian"* ]]; then
        supported=1
    fi

    # RHEL 9 e derivados (Rocky, AlmaLinux, CentOS Stream, Fedora)
    if [[ "${id}" == "rhel" || "${id}" == "rocky" || "${id}" == "almalinux" \
          || "${id}" == "centos" || "${id}" == "fedora" \
          || "${id_like}" == *"rhel"* || "${id_like}" == *"fedora"* ]]; then
        supported=1
        # Aviso (nao bloqueia) se nao for major 9 em distros tipo RHEL
        local major="${VERSION_ID%%.*}"
        if [[ "${id}" == "rhel" || "${id_like}" == *"rhel"* ]]; then
            if [[ -n "${major}" && "${major}" != "9" ]]; then
                warn "testado em RHEL 9; achei major=${major} — prosseguindo"
            fi
        fi
    fi

    if [[ "${supported}" -ne 1 ]]; then
        die "distro nao suportada (esperado Ubuntu/Debian ou RHEL 9, achei: ${id})"
    fi

    ok "SO: ${PRETTY_NAME:-$id} (${arch})"
}

# Define SERVICE_GROUP de acordo com a distro:
#   - Debian/Ubuntu: "nogroup"
#   - RHEL/Fedora:   "nobody"
# Faz fallback olhando /etc/group para nao depender so do ID.
detect_service_group() {
    log "detectando grupo do usuario '${SERVICE_USER}'..."
    if getent group nogroup >/dev/null 2>&1; then
        SERVICE_GROUP="nogroup"
    elif getent group nobody >/dev/null 2>&1; then
        SERVICE_GROUP="nobody"
    else
        die "nem grupo 'nogroup' nem 'nobody' encontrados em /etc/group"
    fi
    ok "grupo do servico: ${SERVICE_GROUP}"
}

require_paths_exist() {
    log "verificando estrutura de diretorios do sistema..."
    local p
    for p in /etc /etc/systemd/system /etc/sysctl.d /opt /var/lib /var/log; do
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

# Cria o diretorio de estado e o arquivo (se ainda nao existe), ambos com
# ownership do usuario do servico. Em reinstalacao NAO recria/zera o
# state.json — preserva as contagens acumuladas.
install_state_dir() {
    log "preparando diretorio de estado em ${STATE_DIR}..."
    install -d -m 0750 -o "${SERVICE_USER}" -g "${SERVICE_GROUP}" "${STATE_DIR}"
    if [[ -f "${STATE_FILE}" ]]; then
        # Garante ownership correto sem mexer no conteudo.
        chown "${SERVICE_USER}:${SERVICE_GROUP}" "${STATE_FILE}"
        ok "estado existente preservado: ${STATE_FILE}"
    else
        ok "diretorio de estado criado (state.json sera gerado no primeiro snapshot)"
    fi
}

# Em sistemas com SELinux ativo (RHEL/Rocky/Alma/Fedora), aplica os labels
# default do filesystem nos arquivos recem-instalados. Sem isso, o binario
# fica com o contexto herdado do build (ex: user_home_t) e o systemd pode
# ser bloqueado ao tentar executa-lo.
apply_selinux_labels() {
    # Se nao tem getenforce/restorecon, nao e sistema com SELinux: sai limpo.
    if ! command -v getenforce >/dev/null 2>&1; then
        return 0
    fi

    local mode
    mode="$(getenforce 2>/dev/null || echo Disabled)"
    if [[ "${mode}" == "Disabled" ]]; then
        ok "SELinux desabilitado — nada a fazer"
        return 0
    fi

    log "SELinux em modo ${mode}; aplicando contextos default..."
    if ! command -v restorecon >/dev/null 2>&1; then
        warn "restorecon nao encontrado (instale 'policycoreutils') — pulando"
        return 0
    fi

    # Diretorio de instalacao + binario + unit + sysctl. restorecon e
    # idempotente e nao falha se o caminho ja estiver correto.
    restorecon -F "${INSTALL_DIR}"  >/dev/null 2>&1 || true
    restorecon -F "${INSTALL_BIN}"  >/dev/null 2>&1 || true
    restorecon -F "${UNIT_FILE}"    >/dev/null 2>&1 || true
    restorecon -F "${SYSCTL_FILE}"  >/dev/null 2>&1 || true
    restorecon -RF "${STATE_DIR}"   >/dev/null 2>&1 || true
    ok "labels SELinux aplicados"
}

install_sysctl() {
    log "configurando sysctl para reservar portas ${DEFAULT_PORT_RANGE}..."
    cat > "${SYSCTL_FILE}" <<EOF
# Reserva as portas usadas pelo ${APP_NAME} para que o kernel nao as
# entregue como ephemeral a outros processos.
net.ipv4.ip_local_reserved_ports = ${DEFAULT_PORT_RANGE}
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
StartLimitIntervalSec=60
StartLimitBurst=10

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
ExecStart=${INSTALL_BIN} \\
  --port-range ${DEFAULT_PORT_RANGE} \\
  --counter-prefix ${DEFAULT_PREFIX} \\
  --http-host ${DEFAULT_HTTP_HOST} \\
  --http-port ${DEFAULT_HTTP_PORT} \\
  --active ${DEFAULT_ACTIVE} \\
  --state-file ${STATE_FILE} \\
  --persist-interval ${DEFAULT_PERSIST_INTERVAL}
Restart=always
RestartSec=3
# Tempo para o flush final do estado antes de SIGKILL.
TimeoutStopSec=10

# Hardening basico.
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
# Permite escrita apenas no diretorio de estado (resto do FS permanece RO).
ReadWritePaths=${STATE_DIR}

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
    echo "  Estado         : ${STATE_FILE} (preservado em reinstalacao)"
    echo "  Unit           : ${UNIT_FILE}"
    echo "  Sysctl         : ${SYSCTL_FILE}"
    echo "  Range UDP      : ${DEFAULT_PORT_RANGE}"
    echo "  HTTP           : ${DEFAULT_HTTP_HOST}:${DEFAULT_HTTP_PORT} (localhost-only, sem auth)"
    echo "  Prefixo nomes  : ${DEFAULT_PREFIX} -> cam5000..cam5249"
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
    require_linux_supported
    require_paths_exist
    require_systemd
    detect_service_group
    require_go
    require_source

    stop_service_if_running
    clean_previous_install

    build_binary
    install_binary
    install_state_dir
    install_sysctl
    install_unit
    apply_selinux_labels
    enable_and_start
    print_summary
}

parse_args "$@"
main
