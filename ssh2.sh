#!/usr/bin/env bash
set -euo pipefail

SSH_BIN="${SSH_BIN:-/tmp/openssh-root/usr/bin/ssh}"
TARGET="${1:-}"
USER_NAME="${2:-}"
REMOTE_CMD="${3:-whoami}"

if [[ ! -x "${SSH_BIN}" ]]; then
  echo "[!] SSH nao encontrado em ${SSH_BIN}"
  echo "[i] Ajuste com: export SSH_BIN=/tmp/openssh-root/usr/bin/ssh"
  exit 1
fi

if ! command -v setsid >/dev/null 2>&1; then
  echo "[!] comando 'setsid' nao encontrado."
  echo "[i] Sem setsid o SSH_ASKPASS sem TTY pode falhar."
  exit 1
fi

if [[ -z "${TARGET}" ]]; then
  read -r -p "Alvo (IP/host): " TARGET
fi

if [[ -z "${USER_NAME}" ]]; then
  read -r -p "Usuario: " USER_NAME
fi

read -r -s -p "Senha: " PASSWORD
echo

if [[ -z "${PASSWORD}" ]]; then
  echo "[!] Senha vazia. Abortando."
  exit 1
fi

ASKPASS_FILE="/tmp/.askpass_${USER_NAME}_$$.sh"
cleanup() {
  rm -f "${ASKPASS_FILE}"
}
trap cleanup EXIT

cat >"${ASKPASS_FILE}" <<EOF
#!/usr/bin/env sh
printf '%s\n' '${PASSWORD}'
EOF
chmod 700 "${ASKPASS_FILE}"

echo "[*] Testando ${USER_NAME}@${TARGET} com comando remoto: ${REMOTE_CMD}"
set +e
DISPLAY=:0 SSH_ASKPASS="${ASKPASS_FILE}" SSH_ASKPASS_REQUIRE=force \
setsid "${SSH_BIN}" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no \
  -o NumberOfPasswordPrompts=1 \
  -o ConnectTimeout=6 \
  "${USER_NAME}@${TARGET}" "${REMOTE_CMD}"
RC=$?
set -e

if [[ ${RC} -eq 0 ]]; then
  echo "[+] Autenticacao/execucao com sucesso."
else
  echo "[-] Falhou (rc=${RC})."
fi

echo
read -r -p "Abrir sessao interativa agora? [s/N]: " OPEN_INTERACTIVE
if [[ "${OPEN_INTERACTIVE}" =~ ^[sS]$ ]]; then
  exec env DISPLAY=:0 SSH_ASKPASS="${ASKPASS_FILE}" SSH_ASKPASS_REQUIRE=force \
    setsid "${SSH_BIN}" -tt \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o PreferredAuthentications=password \
      -o PubkeyAuthentication=no \
      "${USER_NAME}@${TARGET}"
fi
