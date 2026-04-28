#!/usr/bin/env bash
# Wrapper: ssh com password sem TTY (SSH_ASKPASS + setsid), como no ssh_sweep.
# Copia para o pivot (ex.: /tmp/ssh-ask.sh) e usa em vez de colar heredoc sempre.
#
# Uso:
#   SSH_PIVOT_PASS='SENHA' bash ssh_askpass_wrap.sh nick-server@10.20.20.57 'whoami; id'
#   bash ssh_askpass_wrap.sh --pass-file /tmp/p.txt nick-server@10.20.20.57 'ls -la'
#   SSH_BIN=/usr/bin/ssh SSH_PIVOT_PASS='...' bash ssh_askpass_wrap.sh user@host
#
# Variaveis:
#   SSH_BIN          (default: /tmp/openssh-root/usr/bin/ssh, senao primeiro ssh no PATH)
#   SSH_PIVOT_PASS   senha (se nao usar --pass-file)
#   DISPLAY          (default: :0)

set -euo pipefail

_resolve_ssh() {
  if [[ -n "${SSH_BIN:-}" && -x "${SSH_BIN}" ]]; then
    printf '%s' "${SSH_BIN}"
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
# SSH_ASKPASS e invocado sem argumentos; caminho do ficheiro com a senha fica fixo no script.
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
