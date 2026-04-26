#!/bin/bash

echo "[+] Coletando informações da rede..."

# Pega IP automaticamente
IP=$(hostname -I 2>/dev/null | awk '{print $1}')

if [ -z "$IP" ]; then
    echo "[!] hostname -I falhou, usando fallback..."
    IP=$(cat /proc/net/fib_trie | grep -A 1 "host LOCAL" | grep -v "127.0.0.1" | awk '{print $2}' | head -n 1)
fi

echo "[+] Seu IP: $IP"

# Define rede (assume /24)
BASE=$(echo $IP | cut -d '.' -f1-3)

echo "[+] Rede detectada: $BASE.0/24"
echo "[+] Iniciando scan..."

# Portas que vamos testar
PORTS=(22 80 443 3306 8080 6379)

for i in $(seq 1 254); do
    TARGET="$BASE.$i"

    for PORT in "${PORTS[@]}"; do
        timeout 1 bash -c "echo > /dev/tcp/$TARGET/$PORT" 2>/dev/null && \
        echo "[+] $TARGET:$PORT aberto"
    done
done

echo "[+] Scan finalizado."
