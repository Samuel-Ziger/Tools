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
# Password sem TTY: ver ssh_askpass_wrap.sh no mesmo directorio.

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

  cat >"${SSH_ROOT}/ssh-env.sh" <<EOF
export SSH_ROOT="${SSH_ROOT}"
export PATH="\${SSH_ROOT}/usr/bin:\${SSH_ROOT}/usr/sbin:\${PATH}"
export LD_LIBRARY_PATH="${SSH_LD}:\${LD_LIBRARY_PATH:-}"
if [[ -n "\${BASH_VERSION:-}" ]]; then
  hash -r 2>/dev/null || true
fi
EOF
  chmod 644 "${SSH_ROOT}/ssh-env.sh"

  ok "$(env LD_LIBRARY_PATH="${SSH_LD}" "${ssh_bin}" -V 2>&1 | head -1)"
  ok "Prefixo: ${SSH_ROOT}"
  ok "ssh:     ${ssh_bin}"
  ok "Ambiente: source ${SSH_ROOT}/ssh-env.sh"
  ok "Password sem TTY: bash ssh_askpass_wrap.sh (no Kali/repo; copia para o pivot)"

  cat <<EOF

[!] amd64 Bullseye (glibc ~2.31). Em musl ou glibc antigo, nao corre.
[!] Nao mistures extraccao manual repetida no mesmo directorio: apaga o prefixo ou usa SSH_ROOT novo.
[!] Se algum .deb 404, actualiza o array em ${_SCRIPT_PATH##*/} ou OPENSSH_CLIENT_REL.

EOF
}

main "$@"
