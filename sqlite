cat << 'EOF' > /tmp/final_step.sh
#!/bin/bash

echo "--- [1] Buscando Flag em todos os processos Python ---"
for pid in $(pgrep python); do
    echo "Verificando PID: $pid"
    strings /proc/$pid/mem 2>/dev/null | grep -i "Solyd{" && echo "FOUND IN PID $pid!"
done

echo "--- [2] Buscando Flag codificada em Base64 ---"
# "Solyd{" em Base64 costuma começar com "U29seWR7"
grep -ra "U29seWR7" /opt/langflow-1.2.0-venv/ 2>/dev/null

echo "--- [3] Dump de variáveis de ambiente de todos os processos ---"
grep -a "Solyd" /proc/*/environ 2>/dev/null | tr '\0' '\n'

echo "--- [4] Forçando leitura de Custom Components ---"
# Às vezes a flag está no código de um componente que o Langflow carrega
grep -r "Solyd" /opt/langflow-1.2.0-venv/lib/python3.12/site-packages/langflow/components/

echo "--- [5] Verificando logs ocultos do Langflow ---"
find / -name "*.log" -exec grep -l "Solyd" {} + 2>/dev/null
EOF

chmod +x /tmp/final_step.sh
/tmp/final_step.sh
