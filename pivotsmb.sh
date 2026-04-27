#!/usr/bin/env bash
# smbclient + rpcclient em userland (sem root): .deb Debian 11 amd64 + dpkg-deb -x.
# Pensado para pivot onde o Kali nao ve a rede interna mas o alvo tem wget/curl.
#
# Uso no alvo:
#   bash bootstrap_smb_tools_userland.sh
#   source /var/tmp/smb-me/smb-env.sh
#   smbclient -L //10.20.20.19 -N
#   rpcclient -U '' -N 10.20.20.19 -c 'enumdomusers'
#
# Opcional: SMB_ROOT=/var/tmp/smb-me-outro bash bootstrap_smb_tools_userland.sh

set -u

_is_sourced() { [[ "${BASH_SOURCE[0]}" != "${0}" ]]; }
_bail() {
  warn "$*"
  if _is_sourced; then return 1; else exit 1; fi
}

_SCRIPT_PATH="${BASH_SOURCE[0]}"

: "${SMB_ROOT:=/var/tmp/smb-me}"
: "${DEB_DIR:=/tmp/smb-debs}"
# Bullseye amd64 — alinhar com bootstrap_nmap_userland.sh (GLIBC ~2.31).
SAMBA_VER="${SAMBA_VER:-4.13.13+dfsg-1~deb11u7}"
LDB_VER="${LDB_VER:-2.2.3-2~deb11u2}"
SEC_MIRROR="${SEC_MIRROR:-http://security.debian.org/debian-security/pool/updates/main}"
MAIN_MIRROR="${MAIN_MIRROR:-http://ftp.debian.org/debian/pool/main}"

log() { printf '[*] %s\n' "$*"; }
ok()  { printf '[+] %s\n' "$*"; }
warn(){ printf '[!] %s\n' "$*"; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

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

main() {
  if ! need_cmd dpkg-deb; then
    _bail "dpkg-deb nao encontrado."
  fi

  mkdir -p "${DEB_DIR}"
  log "Cache .deb: ${DEB_DIR}"

  # (relpath, base: sec|main)
  local bundles=(
    "s/samba/smbclient_${SAMBA_VER}_amd64.deb|sec"
    "s/samba/samba-common-bin_${SAMBA_VER}_amd64.deb|sec"
    "s/samba/samba-libs_${SAMBA_VER}_amd64.deb|sec"
    "s/samba/samba-common_${SAMBA_VER}_all.deb|sec"
    "s/samba/libsmbclient_${SAMBA_VER}_amd64.deb|sec"
    "s/samba/libwbclient0_${SAMBA_VER}_amd64.deb|sec"
    "s/samba/python3-samba_${SAMBA_VER}_amd64.deb|sec"
    "l/ldb/libldb2_${LDB_VER}_amd64.deb|sec"
    "l/ldb/python3-ldb_${LDB_VER}_amd64.deb|sec"
    "t/tdb/python3-tdb_1.4.3-1+b1_amd64.deb|main"
    "t/tdb/libtdb1_1.4.3-1+b1_amd64.deb|main"
    "t/talloc/python3-talloc_2.3.1-2+b1_amd64.deb|main"
    "t/talloc/libtalloc2_2.3.1-2+b1_amd64.deb|main"
    "t/tevent/libtevent0_0.10.2-1_amd64.deb|main"
    "l/lmdb/liblmdb0_0.9.24-1_amd64.deb|main"
    "p/python3.9/libpython3.9_3.9.2-1_amd64.deb|main"
    "p/python3.9/libpython3.9-minimal_3.9.2-1_amd64.deb|main"
    "p/python3.9/libpython3.9-stdlib_3.9.2-1_amd64.deb|main"
    "p/python3.9/python3.9-minimal_3.9.2-1_amd64.deb|main"
    "p/python3.9/python3.9_3.9.2-1_amd64.deb|main"
    "p/python3-defaults/python3-minimal_3.9.2-3_amd64.deb|main"
    "p/python3-defaults/python3_3.9.2-3_amd64.deb|main"
    "p/python3-defaults/libpython3-stdlib_3.9.2-3_amd64.deb|main"
    "o/openldap/libldap-2.4-2_2.4.57+dfsg-3+deb11u1_amd64.deb|main"
    "c/cyrus-sasl2/libsasl2-2_2.1.27+dfsg-2.1+deb11u1_amd64.deb|main"
    "i/icu/libicu67_67.1-7_amd64.deb|main"
    # Pivot minimal: sem libpopt/libarchive/libbsd/etc. no sistema (ldd "not found").
    "p/popt/libpopt0_1.18-2_amd64.deb|main"
    "liba/libarchive/libarchive13_3.4.3-2+deb11u1_amd64.deb|main"
    "libb/libbsd/libbsd0_0.11.3-1+deb11u1_amd64.deb|main"
    "libm/libmd/libmd0_1.0.3-3_amd64.deb|main"
    "libc/libcap2/libcap2_2.44-1_amd64.deb|main"
    "j/jansson/libjansson4_2.13.1-1.1_amd64.deb|main"
    "a/acl/libacl1_2.2.53-10_amd64.deb|main"
    "b/bzip2/libbz2-1.0_1.0.8-4_amd64.deb|main"
    "l/lz4/liblz4-1_1.9.3-2_amd64.deb|main"
    "x/xz-utils/liblzma5_5.2.5-2.1~deb11u1_amd64.deb|main"
    "z/zlib/zlib1g_1.2.11.dfsg-2+deb11u2_amd64.deb|main"
    "libz/libzstd/libzstd1_1.4.8+dfsg-2.1_amd64.deb|main"
    "libx/libxml2/libxml2_2.9.10+dfsg-6.7+deb11u4_amd64.deb|main"
    "n/nettle/libnettle8_3.7.3-1_amd64.deb|main"
    "n/nettle/libhogweed6_3.7.3-1_amd64.deb|main"
    "g/gnutls28/libgnutls30_3.7.1-5+deb11u5_amd64.deb|main"
    "g/gmp/libgmp10_6.2.1+dfsg-1+deb11u1_amd64.deb|main"
    "libi/libidn2/libidn2-0_2.3.0-5_amd64.deb|main"
    "libu/libunistring/libunistring2_0.9.10-4_amd64.deb|main"
    "libt/libtasn1-6/libtasn1-6_4.16.0-2+deb11u1_amd64.deb|main"
    "p/p11-kit/libp11-kit0_0.23.22-1_amd64.deb|main"
    "libf/libffi/libffi7_3.3-6_amd64.deb|main"
    "d/dbus/libdbus-1-3_1.12.28-0+deb11u1_amd64.deb|main"
    "a/avahi/libavahi-common-data_0.8-5+deb11u2_amd64.deb|main"
    "a/avahi/libavahi-common3_0.8-5+deb11u2_amd64.deb|main"
    "a/avahi/libavahi-client3_0.8-5+deb11u2_amd64.deb|main"
    "p/pam/libpam0g_1.4.0-9+deb11u1_amd64.deb|main"
    "libn/libnsl/libnsl2_1.3.0-2_amd64.deb|main"
    "c/cups/libcups2_2.3.3op2-3+deb11u8_amd64.deb|main"
    "k/krb5/libgssapi-krb5-2_1.18.3-6+deb11u5_amd64.deb|main"
    "k/krb5/libkrb5-3_1.18.3-6+deb11u5_amd64.deb|main"
    "k/krb5/libk5crypto3_1.18.3-6+deb11u5_amd64.deb|main"
    "k/keyutils/libkeyutils1_1.6.1-2_amd64.deb|main"
    "e/e2fsprogs/libcom-err2_1.46.2-2_amd64.deb|main"
    "o/openssl/libssl1.1_1.1.1w-0+deb11u1_amd64.deb|main"
  )

  local entry rel base url name path
  for entry in "${bundles[@]}"; do
    rel="${entry%%|*}"
    base="${entry##*|}"
    name="${rel##*/}"
    path="${DEB_DIR}/${name}"
    if [[ -s "${path}" ]]; then
      log "Ja existe: ${name}"
      continue
    fi
    if [[ "${base}" == "sec" ]]; then
      url="${SEC_MIRROR}/${rel}"
    else
      url="${MAIN_MIRROR}/${rel}"
    fi
    log "Baixando ${name} ..."
    fetch "${url}" "${path}" || _bail "Falha no download. Rede ou mirror."
  done

  local _preferred="${SMB_ROOT}"
  SMB_ROOT="${_preferred}"
  if [[ -e "${SMB_ROOT}" ]]; then
    rm -rf "${SMB_ROOT}" 2>/dev/null || true
    if [[ -e "${SMB_ROOT}" ]]; then
      SMB_ROOT="/tmp/smb-ul-$( (need_cmd id && id -u) || echo 0)-$$"
      warn "Nao deu para apagar ${_preferred}. Novo prefixo: ${SMB_ROOT}"
    fi
  fi
  mkdir -p "${SMB_ROOT}"

  log "Extraindo para ${SMB_ROOT} ..."
  for path in "${DEB_DIR}"/*.deb; do
    [[ -f "${path}" ]] || continue
    dpkg-deb -x "${path}" "${SMB_ROOT}" || _bail "Falha dpkg-deb -x ${path}"
  done

  local libgnu="${SMB_ROOT}/usr/lib/x86_64-linux-gnu"
  local samba_priv="${libgnu}/samba"
  # libs internas (libpopt-samba3-cmdline, libcli-spoolss, ...) ficam em .../samba/
  local SMB_LD="${samba_priv}:${libgnu}:${SMB_ROOT}/lib/x86_64-linux-gnu"

  local smb_bin="${SMB_ROOT}/usr/bin/smbclient"
  if ! env LD_LIBRARY_PATH="${SMB_LD}" "${smb_bin}" -V >/dev/null 2>&1; then
    warn "smbclient -V falhou. Tentativa de diagnostico (ldd):"
    env LD_LIBRARY_PATH="${SMB_LD}" ldd "${smb_bin}" 2>/dev/null | grep 'not found' || true
    _bail "Binario smbclient nao executavel com este LD_LIBRARY_PATH."
  fi

  local launcher="${SMB_ROOT}/smb-pivot.sh"
  cat >"${launcher}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export SMB_ROOT="${SMB_ROOT}"
export PATH="${SMB_ROOT}/usr/bin:${SMB_ROOT}/usr/sbin:\${PATH}"
export LD_LIBRARY_PATH="${SMB_LD}:\${LD_LIBRARY_PATH:-}"
export PYTHONHOME="${SMB_ROOT}/usr"
export PYTHONPATH="${SMB_ROOT}/usr/lib/python3/dist-packages"
exec "\$@"
EOF
  chmod 755 "${launcher}"

  local agent="${SMB_ROOT}/smb-agent.sh"
  cat >"${agent}" <<'AGENT'
#!/usr/bin/env bash
# Agente leve: enum SMB basica contra um IP (139/445).
# Uso: bash smb-agent.sh 10.20.20.19
# Credenciais opcionais: SMB_USER=dom\\user SMB_PASS=secret bash smb-agent.sh 10.20.20.19
set -u
TARGET="${1:-}"
if [[ -z "${TARGET}" ]]; then
  echo "Uso: bash smb-agent.sh <ip-ou-hostname>" >&2
  exit 1
fi
ROOT="$(cd "$(dirname "$0")" && pwd)"
export PATH="${ROOT}/usr/bin:${PATH}"
export LD_LIBRARY_PATH="${ROOT}/usr/lib/x86_64-linux-gnu/samba:${ROOT}/usr/lib/x86_64-linux-gnu:${ROOT}/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
export PYTHONHOME="${ROOT}/usr"
export PYTHONPATH="${ROOT}/usr/lib/python3/dist-packages"

echo "=== smbclient -L //${TARGET} -N (anon) ==="
smbclient -L "//${TARGET}" -N 2>&1 || true

if [[ -n "${SMB_USER:-}" ]]; then
  echo "=== smbclient -L //${TARGET} -U ... (credencial) ==="
  smbclient -L "//${TARGET}" -U "${SMB_USER}%${SMB_PASS:-}" 2>&1 || true
fi

echo "=== rpcclient -U '' -N ${TARGET} -c 'srvinfo' ==="
rpcclient -U '' -N "${TARGET}" -c 'srvinfo' 2>&1 || true

echo "=== rpcclient -U '' -N ${TARGET} -c 'enumdomusers' ==="
rpcclient -U '' -N "${TARGET}" -c 'enumdomusers' 2>&1 || true
AGENT
  chmod 755 "${agent}"

  cat >"${SMB_ROOT}/smb-env.sh" <<EOF
export SMB_ROOT="${SMB_ROOT}"
export PATH="${SMB_ROOT}/usr/bin:${SMB_ROOT}/usr/sbin:\${PATH}"
export LD_LIBRARY_PATH="${SMB_LD}:\${LD_LIBRARY_PATH:-}"
export PYTHONHOME="${SMB_ROOT}/usr"
export PYTHONPATH="${SMB_ROOT}/usr/lib/python3/dist-packages"
EOF
  chmod 644 "${SMB_ROOT}/smb-env.sh"

  ok "smbclient: $(env LD_LIBRARY_PATH="${SMB_LD}" "${smb_bin}" -V | head -1)"
  ok "Launcher: bash ${launcher} smbclient -L //10.20.20.19 -N"
  ok "Agente:   bash ${agent} 10.20.20.19"
  ok "Ambiente: source ${SMB_ROOT}/smb-env.sh"

  cat <<EOF

[!] AVISO: Binarios sao amd64 Bullseye (glibc ~2.31). Em Alpine/musl ou glibc antigo, nao vao correr.
[!] Se faltar alguma .so, acrescente o .deb correspondente ao array em ${_SCRIPT_PATH##*/} e reextraia.

EOF
}

main "$@"
