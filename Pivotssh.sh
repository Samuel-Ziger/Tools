#!/usr/bin/env bash
# Bootstrap de cliente SSH em container Debian bullseye "quebrado":
# - Ajusta sources para archive.debian.org
# - Faz apt update com flags inseguras (lab/CTF)
# - Tenta instalar openssh-client
# - Se dpkg falhar, extrai .deb manualmente para /tmp/openssh-root
# - Exporta PATH/LD_LIBRARY_PATH e testa ssh -V
#
# Uso:
#   bash bootstrap_ssh_pivot.sh
#   bash bootstrap_ssh_pivot.sh --test-login nickj 192.168.80.1
#
# Nota:
#   Este script imprime comandos para "source" no shell atual
#   para manter PATH/LD_LIBRARY_PATH após execução.

set -u

APT_CACHE="/tmp/apt-cache/archives"
SSH_ROOT="/tmp/openssh-root"
SOURCES_FILE="/etc/apt/sources.list"
APT_FLAGS=(
  -o Acquire::Check-Valid-Until=false
  -o Acquire::AllowInsecureRepositories=true
  -o Acquire::AllowDowngradeToInsecureRepositories=true
  -o APT::Get::AllowUnauthenticated=true
  -o Dir::Cache::archives="${APT_CACHE}"
)

log() { printf '[*] %s\n' "$*"; }
ok() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*"; }

ensure_sources() {
  log "Configurando ${SOURCES_FILE} para archive.debian.org (bullseye)..."
  cat > "${SOURCES_FILE}" <<'EOF'
deb [trusted=yes] http://archive.debian.org/debian bullseye main contrib non-free
deb [trusted=yes] http://archive.debian.org/debian bullseye-updates main contrib non-free
EOF
}

apt_update() {
  log "Criando cache APT temporario em ${APT_CACHE}..."
  mkdir -p "${APT_CACHE}/partial"
  log "Atualizando indices do APT..."
  apt-get "${APT_FLAGS[@]}" update
}

install_openssh() {
  log "Tentando instalar openssh-client via apt..."
  if apt-get "${APT_FLAGS[@]}" install -y openssh-client; then
    ok "openssh-client instalado pelo apt."
    return 0
  fi
  warn "Instalacao via apt/dpkg falhou; tentando fallback por extracao de .deb."
  return 1
}

extract_debs_fallback() {
  local found=0
  log "Extraindo pacotes .deb para ${SSH_ROOT}..."
  mkdir -p "${SSH_ROOT}"
  for deb in "${APT_CACHE}"/*.deb; do
    if [[ -f "${deb}" ]]; then
      found=1
      dpkg-deb -x "${deb}" "${SSH_ROOT}"
    fi
  done
  if [[ "${found}" -eq 0 ]]; then
    warn "Nenhum .deb encontrado em ${APT_CACHE}. Falha no fallback."
    return 1
  fi
  ok "Fallback concluido com extracao de .deb."
}

activate_env() {
  local p1="${SSH_ROOT}/usr/bin"
  local l1="${SSH_ROOT}/usr/lib/x86_64-linux-gnu"
  local l2="${SSH_ROOT}/lib/x86_64-linux-gnu"

  export PATH="${p1}:${PATH}"
  export LD_LIBRARY_PATH="${l1}:${l2}:${LD_LIBRARY_PATH:-}"

  if command -v ssh >/dev/null 2>&1; then
    ok "ssh encontrado em: $(command -v ssh)"
  else
    warn "ssh nao encontrado no PATH mesmo apos bootstrap."
    return 1
  fi

  ssh -V || {
    warn "Falha ao executar ssh -V (possivel falta de biblioteca)."
    return 1
  }
}

print_source_hint() {
  cat <<EOF

[+] Para manter variaveis no shell atual, roda:
    source "$0"

Ou exporta manualmente:
    export PATH="${SSH_ROOT}/usr/bin:\$PATH"
    export LD_LIBRARY_PATH="${SSH_ROOT}/usr/lib/x86_64-linux-gnu:${SSH_ROOT}/lib/x86_64-linux-gnu:\$LD_LIBRARY_PATH"
EOF
}

test_login_if_requested() {
  if [[ "${1:-}" == "--test-login" ]]; then
    local user="${2:-}"
    local host="${3:-}"
    if [[ -z "${user}" || -z "${host}" ]]; then
      warn "Uso: $0 --test-login <user> <host>"
      return 1
    fi
    log "Testando SSH para ${user}@${host}..."
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${user}@${host}"
  fi
}

main() {
  ensure_sources
  apt_update

  if ! install_openssh; then
    extract_debs_fallback
    activate_env
  else
    ssh -V || warn "openssh instalado, mas ssh -V falhou."
  fi

  ok "Bootstrap SSH finalizado."
  print_source_hint
  test_login_if_requested "${1:-}" "${2:-}" "${3:-}"
}

main "${@:-}"
