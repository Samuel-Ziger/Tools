#!/usr/bin/env bash
# Scanner TCP simples (connect scan) com bash /dev/tcp — sem nmap/nc.
# Requer bash (POSIX sh não tem /dev/tcp).

set -u

TIMEOUT="${TIMEOUT:-1}"   # segundos (aprox., via sleep 0.1)
VERBOSE=0

usage() {
  echo "Uso: $0 <HOST|IP> [-p PORTAS] [-t TIMEOUT_SEG] [-v]"
  echo ""
  echo "  -p PORTAS   Ex.: 22,80,443  |  1-1024  |  80,8000-8010"
  echo "  -t N        Timeout máx. por porta (default: ${TIMEOUT})"
  echo "  -v          Mostra também portas fechadas"
  echo ""
  echo "Sem -p, usa lista curta de portas comuns."
  exit 1
}

# Tenta conectar via /dev/tcp com limite de tempo (sem `timeout` externo).
check_tcp() {
  local host="$1"
  local port="$2"
  local max=$(( TIMEOUT * 10 )) # décimos de segundo
  local i=0

  bash -c "echo -n >/dev/tcp/${host}/${port}" 2>/dev/null &
  local pid=$!

  while kill -0 "${pid}" 2>/dev/null; do
    ((i++)) || true
    if (( i > max )); then
      kill -9 "${pid}" 2>/dev/null
      wait "${pid}" 2>/dev/null || true
      return 1
    fi
    sleep 0.1
  done

  wait "${pid}"
}

expand_ports() {
  local spec="$1"
  local IFS=,
  local part a b i
  for part in ${spec}; do
    if [[ "${part}" == *-* ]]; then
      a="${part%-*}"
      b="${part#*-}"
      [[ "${a}" =~ ^[0-9]+$ && "${b}" =~ ^[0-9]+$ ]] || continue
      for ((i=a; i<=b; i++)); do
        echo "${i}"
      done
    else
      echo "${part}"
    fi
  done
}

HOST=""
PORTS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) PORTS="$2"; shift 2 ;;
    -t) TIMEOUT="$2"; shift 2 ;;
    -v) VERBOSE=1; shift ;;
    -h|--help) usage ;;
    *)
      if [[ -z "${HOST}" ]]; then
        HOST="$1"
        shift
      else
        echo "[!] Argumento extra: $1"
        usage
      fi
      ;;
  esac
done

[[ -n "${HOST}" ]] || usage

if [[ -z "${PORTS}" ]]; then
  PORTS="21,22,25,53,80,110,143,443,445,3306,3389,5432,6379,8080,8443,9000,27017"
fi

echo "[*] Alvo: ${HOST}"
echo "[*] Timeout ~${TIMEOUT}s por porta"
echo "[*] Portas: ${PORTS}"
echo ""

mapfile -t PORT_LIST < <(expand_ports "${PORTS}" | sort -n -u)

opens=0
for p in "${PORT_LIST[@]}"; do
  [[ "${p}" =~ ^[0-9]+$ ]] || continue
  (( p >= 1 && p <= 65535 )) || continue
  if check_tcp "${HOST}" "${p}"; then
    printf "[+] OPEN   tcp/%s\n" "${p}"
    ((opens++)) || true
  else
    if [[ "${VERBOSE}" -eq 1 ]]; then
      printf "[.] closed tcp/%s\n" "${p}"
    fi
  fi
done

echo ""
echo "[*] Total OPEN: ${opens}"
