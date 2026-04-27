#!/usr/bin/env bash
# Nmap em userland (sem root): baixa .deb do Debian bullseye em /tmp e extrai
# com dpkg-deb -x (nao passa por dpkg install no sistema).
#
# Uso no alvo (shell sem sudo):
#   bash bootstrap_nmap_userland.sh
#   source bootstrap_nmap_userland.sh   # mantem PATH/LD_LIBRARY_PATH no shell atual
#
# Se o apt anterior deixou cache em /var/cache/apt/archives sem permissao de apagar,
# ignore os erros de rm — este script nao usa esse diretorio.

set -u

# Ao ser "source", nao usar exit (mata o shell do operador).
_is_sourced() { [[ "${BASH_SOURCE[0]}" != "${0}" ]]; }
_bail() {
  warn "$*"
  if _is_sourced; then return 1; else exit 1; fi
}

_SCRIPT_PATH="${BASH_SOURCE[0]}"

# Defaults (main() pode mudar NMAP_ROOT se /tmp/nmap-root nao for apagavel).
: "${NMAP_ROOT:=/tmp/nmap-root}"
: "${DEB_DIR:=/tmp/nmap-debs}"
MIRROR="${MIRROR:-http://archive.debian.org/debian/pool/main}"

log() { printf '[*] %s\n' "$*"; }
ok()  { printf '[+] %s\n' "$*"; }
warn(){ printf '[!] %s\n' "$*"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

fetch() {
  local url="$1"
  local out="$2"
  if need_cmd wget; then
    wget -q -c -O "${out}" "${url}" && return 0
    warn "wget falhou para: ${url}"
    return 1
  fi
  if need_cmd curl; then
    curl -fsSL -o "${out}" "${url}" && return 0
    warn "curl falhou para: ${url}"
    return 1
  fi
  warn "Sem wget/curl para baixar: ${url}"
  return 1
}

main() {
  if ! need_cmd dpkg-deb; then
    _bail "dpkg-deb nao encontrado (pacote dpkg). Tente mini_nmap.sh com bash."
  fi

  mkdir -p "${DEB_DIR}"
  log "Cache de .deb: ${DEB_DIR}"

  # Bullseye amd64 — sem o pacote "dbus" (daemon; polui etc/ e systemd).
  # libpcap0.8 no Debian liga a libdbus-1.so.3 -> precisa de libdbus-1-3 (só libs em lib/).
  local debs=(
    "l/lapack/libblas3_3.9.0-3+deb11u1_amd64.deb"
    "libl/liblinear/liblinear4_2.3.0+dfsg-5_amd64.deb"
    "l/lua5.3/liblua5.3-0_5.3.3-1.1+deb11u1_amd64.deb"
    "d/dbus/libdbus-1-3_1.12.28-0+deb11u1_amd64.deb"
    "libp/libpcap/libpcap0.8_1.10.0-2_amd64.deb"
    "l/lua-lpeg/lua-lpeg_1.0.2-1_amd64.deb"
    "o/openssl/libssl1.1_1.1.1w-0+deb11u1_amd64.deb"
    "p/pcre3/libpcre3_8.39-13_amd64.deb"
    "libs/libssh2/libssh2-1_1.9.0-2+deb11u1_amd64.deb"
    "n/nmap/nmap-common_7.91+dfsg1+really7.80+dfsg1-2_all.deb"
    "n/nmap/nmap_7.91+dfsg1+really7.80+dfsg1-2_amd64.deb"
  )

  local rel name path url
  for rel in "${debs[@]}"; do
    name="${rel##*/}"
    path="${DEB_DIR}/${name}"
    url="${MIRROR}/${rel}"
    if [[ -s "${path}" ]]; then
      log "Ja existe: ${name}"
      continue
    fi
    log "Baixando ${name} ..."
    if ! fetch "${url}" "${path}"; then
      _bail "Falha no download. Verifique rede/MIRROR ou firewall do alvo."
    fi
  done

  local _preferred="${NMAP_ROOT}"
  log "Prefixo preferido: ${_preferred}"
  NMAP_ROOT="${_preferred}"
  if [[ -e "${NMAP_ROOT}" ]]; then
    rm -rf "${NMAP_ROOT}" 2>/dev/null || true
    if [[ -e "${NMAP_ROOT}" ]]; then
      NMAP_ROOT="/tmp/nmap-ul-$( (command -v id >/dev/null 2>&1 && id -u) || echo 0)-$$"
      warn "Nao deu para apagar ${_preferred} (arquivos de outro usuario/root?). Novo prefixo: ${NMAP_ROOT}"
    fi
  fi
  mkdir -p "${NMAP_ROOT}"

  log "Extraindo apenas os .deb da lista (ignora dbus antigo em ${DEB_DIR}) ..."
  for rel in "${debs[@]}"; do
    name="${rel##*/}"
    path="${DEB_DIR}/${name}"
    if [[ ! -s "${path}" ]]; then
      _bail "Falta .deb: ${path}"
    fi
    dpkg-deb -x "${path}" "${NMAP_ROOT}" || {
      _bail "Falha ao extrair: ${path}"
    }
  done

  local libgnu="${NMAP_ROOT}/usr/lib/x86_64-linux-gnu"
  # Somente o bundle no teste (evita LD_LIBRARY_PATH herdado quebrado no alvo).
  local NMAP_LD="${libgnu}:${libgnu}/blas:${libgnu}/engines-1.1:${NMAP_ROOT}/lib/x86_64-linux-gnu"

  if [[ ! -e "${libgnu}/libpcap.so.0.8" && ! -e "${libgnu}/libpcap.so.1.10.0" ]]; then
    warn "libpcap ausente apos extracao (esperado em ${libgnu}). Listando:"
    ls -la "${libgnu}" 2>/dev/null | head -30 || true
    _bail "Pacote libpcap0.8 nao apareceu no prefixo. Apague /tmp/nmap-debs/*.deb e rode de novo se os .deb estiverem corrompidos."
  fi

  export PATH="${NMAP_ROOT}/usr/bin:${NMAP_ROOT}/usr/sbin:${PATH}"
  # libblas3 (lapack) instala em .../blas/
  export LD_LIBRARY_PATH="${NMAP_LD}:${LD_LIBRARY_PATH:-}"

  local nmap_bin="${NMAP_ROOT}/usr/bin/nmap"
  if env LD_LIBRARY_PATH="${NMAP_LD}" PATH="${NMAP_ROOT}/usr/bin:${NMAP_ROOT}/usr/sbin:${PATH}" "${nmap_bin}" --version >/dev/null 2>&1; then
    ok "nmap OK: $(env LD_LIBRARY_PATH="${NMAP_LD}" PATH="${NMAP_ROOT}/usr/bin:${NMAP_ROOT}/usr/sbin:${PATH}" "${nmap_bin}" --version | head -1)"
  else
    warn "Binario presente mas nmap --version falhou (falta lib?)."
    env LD_LIBRARY_PATH="${NMAP_LD}" PATH="${NMAP_ROOT}/usr/bin:${NMAP_ROOT}/usr/sbin:${PATH}" "${nmap_bin}" --version || true
    _bail "nmap nao executavel."
  fi

  # Launcher: funciona mesmo depois de apenas `bash` no script (sem source).
  local launcher="${NMAP_ROOT}/nmap-pivot.sh"
  cat >"${launcher}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export NMAP_ROOT="${NMAP_ROOT}"
export PATH="${NMAP_ROOT}/usr/bin:${NMAP_ROOT}/usr/sbin:\${PATH}"
export LD_LIBRARY_PATH="${NMAP_LD}:\${LD_LIBRARY_PATH:-}"
exec "${nmap_bin}" "\$@"
EOF
  chmod 755 "${launcher}"
  ok "Launcher (use sem precisar source): bash ${launcher} --version"

  cat <<EOF

[+] IMPORTANTE:
    - Rodar só "bash ${_SCRIPT_PATH##*/}" NAO deixa o nmap no teu shell (subprocesso).
    - Opcao A — carregar no shell atual:
        source ${_SCRIPT_PATH}
    - Opcao B — sem poluir PATH (recomendado):
        bash ${launcher} -Pn -p 22,80,443 --open 127.0.0.1

[+] Se copiar exports manualmente, use "export" (nao "xport") numa linha so, ex.:
    export NMAP_ROOT=${NMAP_ROOT}
    export PATH="${NMAP_ROOT}/usr/bin:${NMAP_ROOT}/usr/sbin:\$PATH"
    export LD_LIBRARY_PATH="${NMAP_LD}:\${LD_LIBRARY_PATH:-}"
EOF
}

main "$@"
ret=$?
if _is_sourced; then
  return "${ret}"
fi
exit "${ret}"
