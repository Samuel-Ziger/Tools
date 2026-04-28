#!/usr/bin/env bash
# Cliente OpenSSH (ssh, scp, sftp) em userland: so wget/curl + dpkg-deb -x.
# Nao usa apt nem escreve em /etc/apt (pivot sem root).
#
# Evita o erro do "Pivotssh.sh" com tar: destino e apagado antes de extrair
# (arvore antiga em /tmp/openssh-root causa "File exists" / "Cannot utime").
#
# Se dpkg-deb falhar por libs herdadas do SMB, rode:
#   env -u LD_LIBRARY_PATH bash bootstrap_openssh_client_userland.sh
#
# Uso no alvo:
#   bash bootstrap_openssh_client_userland.sh
#   source /var/tmp/openssh-me/ssh-env.sh
#   ssh -V
# Ou caminho fixo:
#   SSH_ROOT=/tmp/openssh-root bash bootstrap_openssh_client_userland.sh
#
# Password sem TTY: apos o bootstrap fica em SSH_ROOT/ssh_askpass_wrap.sh

set -u

_SCRIPT_PATH="${BASH_SOURCE[0]}"
MAIN_MIRROR="${MAIN_MIRROR:-http://ftp.debian.org/debian/pool/main}"
: "${SSH_ROOT:=/var/tmp/openssh-me}"
: "${DEB_DIR:=/tmp/openssh-debs}"
# Override opcional: relativo a MAIN_MIRROR (ex.: o/openssh/openssh-client_8.4p1-5+deb11u4_amd64.deb).
: "${OPENSSH_CLIENT_REL:=o/openssh/openssh-client_8.4p1-5+deb11u3_amd64.deb}"

log() { printf '[*] %s\n' "$*"; }
ok()  { printf '[+] %s\n' "$*"; }
warn(){ printf '[!] %s\n' "$*"; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

# dpkg-deb liga-se a liblzma do sistema; LD_LIBRARY_PATH do SMB pode injectar liblzma
# mais nova e falhar com "version XZ_* not found".
dpkg_deb_x() {
  env -u LD_LIBRARY_PATH dpkg-deb -x "$1" "$2"
}

fetch() {
  local url="$1"
  local out="$2"
  if need_cmd wget; then
    wget -q -c -O "${out}" "${url}" && return 0
    warn "wget falhou: ${url}"
    return 1
  fi
  if need_cmd curl; then
    curl -fsSL -o "${out}" "${url}" && return 0
    warn "curl falhou: ${url}"
    return 1
  fi
  warn "Sem wget/curl."
  return 1
}

bail() {
  warn "$*"
  exit 1
}

main() {
  if ! need_cmd dpkg-deb; then
    bail "dpkg-deb nao encontrado (instale dpkg ou use maquina Debian-like)."
  fi

  if [[ "$(id -u 2>/dev/null || echo 1)" -eq 0 ]]; then
    warn "Corres como root: este script NAO altera sources.list nem apt; so extrai .deb."
  fi

  mkdir -p "${DEB_DIR}"
  log "Cache .deb: ${DEB_DIR}"

  # Relativos a MAIN_MIRROR (ftp.debian.org/pool/main/...). Nomes sem epoch na URL.
  local bundles=(
    "${OPENSSH_CLIENT_REL}"
    "o/openssl/libssl1.1_1.1.1w-0+deb11u1_amd64.deb"
    "z/zlib/zlib1g_1.2.11.dfsg-2+deb11u2_amd64.deb"
    "k/krb5/libgssapi-krb5-2_1.18.3-6+deb11u5_amd64.deb"
    "k/krb5/libkrb5-3_1.18.3-6+deb11u5_amd64.deb"
    "k/krb5/libk5crypto3_1.18.3-6+deb11u5_amd64.deb"
    "k/krb5/libkrb5support0_1.18.3-6+deb11u5_amd64.deb"
    "k/keyutils/libkeyutils1_1.6.1-2_amd64.deb"
    "e/e2fsprogs/libcom-err2_1.46.2-2_amd64.deb"
    "p/pam/libpam0g_1.4.0-9+deb11u1_amd64.deb"
    "a/audit/libaudit1_3.0-2_amd64.deb"
    "libs/libselinux/libselinux1_3.1-3_amd64.deb"
    "s/systemd/libsystemd0_247.3-7+deb11u5_amd64.deb"
    "x/xz-utils/liblzma5_5.2.5-2.1~deb11u1_amd64.deb"
    "libz/libzstd/libzstd1_1.4.8+dfsg-2.1_amd64.deb"
    "libb/libbsd/libbsd0_0.11.3-1+deb11u1_amd64.deb"
    "libm/libmd/libmd0_1.0.3-3_amd64.deb"
    "libc/libcbor/libcbor0_0.5.0+dfsg-2_amd64.deb"
    "libe/libedit/libedit2_3.1-20191231-2+b1_amd64.deb"
    "libf/libfido2/libfido2-1_1.6.0-2_amd64.deb"
    "t/tcp-wrappers/libwrap0_7.6.q-31_amd64.deb"
    # X11 / xauth (recomendacoes openssh-client; X11 forward)
    "x/xauth/xauth_1.1-1_amd64.deb"
    "libx/libxmu/libxmuu1_1.1.3-3_amd64.deb"
    "libx/libx11/libx11-6_1.7.2-1+deb11u2_amd64.deb"
    "libx/libx11/libx11-data_1.7.2-1+deb11u2_all.deb"
    "libx/libxau/libxau6_1.0.9-1_amd64.deb"
    "libx/libxcb/libxcb1_1.14-3_amd64.deb"
    "libx/libxdmcp/libxdmcp6_1.1.2-3_amd64.deb"
    "libx/libxext/libxext6_1.3.4-1+b1_amd64.deb"
  )

  local rel url name path
  for rel in "${bundles[@]}"; do
    name="${rel##*/}"
    path="${DEB_DIR}/${name}"
    if [[ -s "${path}" ]]; then
      log "Ja existe: ${name}"
      continue
    fi
    url="${MAIN_MIRROR}/${rel}"
    log "Baixando ${name} ..."
    fetch "${url}" "${path}" || bail "Falha no download. Rede, mirror ou OPENSSH_CLIENT_REL."
  done

  local _preferred="${SSH_ROOT}"
  if [[ -e "${SSH_ROOT}" ]]; then
    rm -rf "${SSH_ROOT}" 2>/dev/null || true
    if [[ -e "${SSH_ROOT}" ]]; then
      SSH_ROOT="/tmp/openssh-ul-$( (need_cmd id && id -u) || echo 0)-$$"
      warn "Nao deu para apagar ${_preferred}. Novo prefixo: ${SSH_ROOT}"
    fi
  fi
  mkdir -p "${SSH_ROOT}"

  log "Extraindo para ${SSH_ROOT} (destino vazio) ..."
  for path in "${DEB_DIR}"/*.deb; do
    [[ -f "${path}" ]] || continue
    dpkg_deb_x "${path}" "${SSH_ROOT}" || bail "Falha dpkg-deb -x ${path}"
  done

  local libgnu="${SSH_ROOT}/usr/lib/x86_64-linux-gnu"
  local lib64="${SSH_ROOT}/lib/x86_64-linux-gnu"
  local SSH_LD="${libgnu}:${lib64}"

  local ssh_bin="${SSH_ROOT}/usr/bin/ssh"
  if ! env LD_LIBRARY_PATH="${SSH_LD}" "${ssh_bin}" -V >/dev/null 2>&1; then
    warn "ssh -V falhou. Diagnostico (ldd):"
    env LD_LIBRARY_PATH="${SSH_LD}" ldd "${ssh_bin}" 2>/dev/null | grep 'not found' || true
    bail "Binario ssh nao executavel com este LD_LIBRARY_PATH."
  fi

  # BASH_SOURCE: source /ABS/ssh-env.sh funciona mesmo se SSH_ROOT nao estiver na shell
  # (evita expandir para /ssh-env.sh quando SSH_ROOT esta vazio).
  cat >"${SSH_ROOT}/ssh-env.sh" <<EOF
# Gerado por bootstrap_openssh_client_userland.sh — usar sempre caminho absoluto:
#   source ${SSH_ROOT}/ssh-env.sh
if [[ -n "\${BASH_SOURCE[0]:-}" ]]; then
  SSH_ROOT="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
else
  echo "[!] ssh-env.sh: usa bash (source ...) ou exporta SSH_ROOT=${SSH_ROOT}" >&2
  return 1 2>/dev/null || exit 1
fi
export SSH_ROOT
export PATH="\${SSH_ROOT}/usr/bin:\${SSH_ROOT}/usr/sbin:\${PATH}"
export LD_LIBRARY_PATH="${SSH_LD}:\${LD_LIBRARY_PATH:-}"
if [[ -n "\${BASH_VERSION:-}" ]]; then
  hash -r 2>/dev/null || true
fi
EOF
  chmod 644 "${SSH_ROOT}/ssh-env.sh"

  # So copiamos ssh_askpass_wrap.sh ao lado do bootstrap se for MESMO o wrapper (~100 linhas).
  # Se alguem gravou o Pivotssh em cima de ssh_askpass_wrap.sh (mesmo conteudo OPENSSH_CLIENT_REL),
  # o cp estragava ${SSH_ROOT}/ssh_askpass_wrap.sh — ignorar e usar o heredoc embutido.
  local _wrap_dest="${SSH_ROOT}/ssh_askpass_wrap.sh"
  local _wrap_src=""
  local _wrap_copied=0
  local _wrap_dir
  _wrap_dir="$(cd "$(dirname "${_SCRIPT_PATH}")" && pwd)"
  # Com "bash pivotssh.sh" desde /, dirname e "." e pwd e "/" — evitar //ssh_askpass_wrap.sh
  case "${_wrap_dir}" in
    /) _wrap_src="/ssh_askpass_wrap.sh" ;;
    *) _wrap_src="${_wrap_dir}/ssh_askpass_wrap.sh" ;;
  esac
  if [[ -f "${_wrap_src}" ]]; then
    if grep -q '_resolve_ssh()' "${_wrap_src}" 2>/dev/null && ! grep -q 'OPENSSH_CLIENT_REL' "${_wrap_src}" 2>/dev/null; then
      cp -f "${_wrap_src}" "${_wrap_dest}" 2>/dev/null && _wrap_copied=1
    else
      warn "Ignorando ${_wrap_src} (parece Pivotssh/bootstrap, nao o wrapper). A instalar wrapper embutido."
    fi
  fi
  if [[ "${_wrap_copied}" -eq 0 ]]; then
    cat >"${_wrap_dest}" <<'SSHWRAP'
#!/usr/bin/env bash
# Wrapper: ssh com password sem TTY (SSH_ASKPASS + setsid), como no ssh_sweep.
#
# Uso:
#   source .../ssh-env.sh
#   printf '%s' 'SENHA' > /tmp/.p && chmod 600 /tmp/.p
#   bash SSH_ROOT/ssh_askpass_wrap.sh --pass-file /tmp/.p user@host 'ls -la'
#
# Variaveis: SSH_BIN, SSH_ROOT, SSH_PIVOT_PASS, DISPLAY

set -euo pipefail

_resolve_ssh() {
  if [[ -n "${SSH_BIN:-}" && -x "${SSH_BIN}" ]]; then
    printf '%s' "${SSH_BIN}"
    return
  fi
  if [[ -n "${SSH_ROOT:-}" && -x "${SSH_ROOT}/usr/bin/ssh" ]]; then
    printf '%s' "${SSH_ROOT}/usr/bin/ssh"
    return
  fi
  if [[ -x "/var/tmp/openssh-me/usr/bin/ssh" ]]; then
    printf '%s' "/var/tmp/openssh-me/usr/bin/ssh"
    return
  fi
  if [[ -x "/tmp/openssh-root/usr/bin/ssh" ]]; then
    printf '%s' "/tmp/openssh-root/usr/bin/ssh"
    return
  fi
  command -v ssh
}

usage() {
  printf '%s\n' "Uso:" \
    "  SSH_PIVOT_PASS='senha' bash $0 user@host ['comando remoto']" \
    "  bash $0 --pass-file /caminho user@host ['comando remoto']" >&2
  exit 1
}

[[ "${#}" -lt 1 ]] && usage

PASS=""
if [[ "${1:-}" == "--pass-file" ]]; then
  [[ "${#}" -lt 3 ]] && usage
  PASS="$(cat "$2")"
  shift 2
fi

TARGET="${1:-}"
[[ -z "${TARGET}" ]] && usage
shift
REMOTE="${*:-whoami}"

if [[ -z "${PASS}" ]]; then
  PASS="${SSH_PIVOT_PASS:-}"
fi
[[ -z "${PASS}" ]] && {
  echo "[!] Defina SSH_PIVOT_PASS ou --pass-file" >&2
  usage
}

if ! command -v setsid >/dev/null 2>&1; then
  echo "[!] setsid nao encontrado (pacote util-linux)." >&2
  exit 1
fi

SSH_BIN="$(_resolve_ssh)"
SECRET="/tmp/.ssh_askpass_secret_$$"
ASK="/tmp/.ssh_askpass_wrap_$$.sh"
cleanup() {
  rm -f "${ASK}" "${SECRET}"
}
trap cleanup EXIT

umask 077
printf '%s' "${PASS}" >"${SECRET}"
printf '#!/bin/sh\ncat %q\n' "${SECRET}" >"${ASK}"
chmod 700 "${ASK}" "${SECRET}"

export DISPLAY="${DISPLAY:-:0}"
export SSH_ASKPASS="${ASK}"
export SSH_ASKPASS_REQUIRE=force

exec setsid "${SSH_BIN}" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o PreferredAuthentications=password,keyboard-interactive \
  -o PubkeyAuthentication=no \
  -o IdentitiesOnly=yes \
  -o NumberOfPasswordPrompts=1 \
  -o ConnectTimeout="${SSH_CONNECT_TIMEOUT:-12}" \
  "${TARGET}" "${REMOTE}"
SSHWRAP
  fi
  chmod 755 "${_wrap_dest}"

  ok "$(env LD_LIBRARY_PATH="${SSH_LD}" "${ssh_bin}" -V 2>&1 | head -1)"
  ok "Prefixo: ${SSH_ROOT}"
  ok "ssh:     ${ssh_bin}"
  ok "Ambiente (copia a linha exacta): source ${SSH_ROOT}/ssh-env.sh"
  ok "SSH+password (recom.: --pass-file): bash ${SSH_ROOT}/ssh_askpass_wrap.sh --pass-file /tmp/.p USER@HOST 'cmd'"

  cat <<EOF

[!] Se o script mudou o prefixo (ex.: nao deu para apagar /tmp/openssh-root), o SSH_ROOT da
    tua shell NAO foi actualizado — usa o "Prefixo:" acima, NAO source "\$SSH_ROOT/ssh-env.sh".
[!] Senha com '!': bash interactivo expande historico; use printf '%s' 'SENHA' > /tmp/.p
    (abre e fecha aspas simples em volta da senha) ou: set +H  antes do printf.
[!] amd64 Bullseye (glibc ~2.31). Em musl ou glibc antigo, nao corre.
[!] Nao mistures extraccao manual repetida no mesmo directorio: apaga o prefixo ou usa SSH_ROOT novo.
[!] Se algum .deb 404, actualiza o array em ${_SCRIPT_PATH##*/} ou OPENSSH_CLIENT_REL.

EOF
}

main "$@"
