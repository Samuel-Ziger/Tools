#!/bin/bash

# Cores para a saída no terminal
GREEN='\033[0;32m' # Verde para status 200 (OK)
YELLOW='\033[1;33m' # Amarelo para status 403 (Forbidden)
RED='\033[0;31m'   # Vermelho para status 404 (Not Found)
BLUE='\033[0;34m'  # Azul para informações e cabeçalhos
NC='\033[0m'       # Sem cor (volta ao padrão do terminal)

# --- Função de Ajuda (Usage) ---
usage() {
    echo -e "${BLUE}--------------------------------------------------------------------------------------------------------------------------------------${NC}"
    echo -e "${BLUE}"
    echo "   ██████╗ ██╗  ██╗ ██████╗ ███████╗████████╗███╗   ███╗ █████╗ ██████╗ ██████╗ ███████╗██████╗ "
    echo "  ██╔════╝ ██║  ██║██╔═══██╗██╔════╝╚══██╔══╝████╗ ████║██╔══██╗██╔══██╗██╔══██╗██╔════╝██╔══██╗"
    echo "  ██║  ███╗███████║██║   ██║███████╗   ██║   ██╔████╔██║███████║██████╔╝██████╔╝█████╗  ██████╔╝"
    echo "  ██║   ██║██╔══██║██║   ██║╚════██║   ██║   ██║╚██╔╝██║██╔══██║██╔═══╝ ██╔═══╝ ██╔══╝  ██╔══██╗"
    echo "  ╚██████╔╝██║  ██║╚██████╔╝███████║   ██║   ██║ ╚═╝ ██║██║  ██║██║     ██║     ███████╗██║  ██║"
    echo "   ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚══════╝   ╚═╝   ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝     ╚═╝     ╚══════╝╚═╝  ╚═╝"
    echo ""
    echo "                👻 GhostMapper - Directory Scanner 👻"
    echo -e "${NC}"
    echo -e "${BLUE}-------------------------------------------------------------------------------------------------------------------------------------${NC}"

    echo -e "Uso: \$0 -u <URL_alvo> -w <arquivo_wordlist>"
    echo -e ""
    echo -e "Opções:"
    echo -e "  -u <URL>       URL alvo (ex: http://exemplo.com ou https://exemplo.com/diretorio/)"
    echo -e "  -w <arquivo>   Caminho para o arquivo da wordlist (um diretório/arquivo por linha)"
    echo -e "  -h             Exibe esta mensagem de ajuda"
    echo -e ""
    echo -e "Exemplo:"
    echo -e "  \$0 -u https://www.exemplo.com -w /usr/share/wordlists/dirb/common.txt"
    echo -e "${BLUE}-------------------------------------------------------------------------------------------------------------------------------------${NC}"
    exit 1
}

# --- Variáveis para armazenar os argumentos ---
TARGET_URL=""
WORDLIST_FILE=""

# --- Parseamento de Argumentos usando getopts ---
# O ":" após "u" e "w" indica que essas opções exigem um argumento.
while getopts "hu:w:" opt; do
    case ${opt} in
        h ) # Opção de ajuda
            usage
            ;;
        u ) # URL alvo
            TARGET_URL=$OPTARG
            ;;
        w ) # Arquivo da wordlist
            WORDLIST_FILE=$OPTARG
            ;;
        \? ) # Opção inválida
            echo -e "${RED}Erro: Opção inválida -$OPTARG${NC}" >&2
            usage
            ;;
        : ) # Opção sem argumento necessário
            echo -e "${RED}Erro: A opção -$OPTARG requer um argumento.${NC}" >&2
            usage
            ;;
    esac
done

#  remove os argumentos já processados para que 

# --- Validação dos argumentos essenciais ---
if [[ -z "$TARGET_URL" || -z "$WORDLIST_FILE" ]]; then
    echo -e "${RED}Erro: URL alvo (-u) e arquivo de wordlist (-w) são obrigatórios.${NC}" >&2
    usage
fi

# --- Valida o arquivo da wordlist ---
if [[ ! -f "$WORDLIST_FILE" ]]; then
    echo -e "${RED}Erro: O arquivo da wordlist '$WORDLIST_FILE' não foi encontrado.${NC}" >&2
    exit 1
fi

# --- Ajusta a URL alvo para garantir que termina com uma barra, se não for um domínio raiz ---
# Isso ajuda a construir URLs corretamente (ex: http://exemplo.com/admin)
# Se a URL não termina com '/', adiciona uma. Ex: "http://example.com" vira "http://example.com/"
# E "http://example.com/app" vira "http://example.com/app/"
if [[ "$TARGET_URL" != */ ]]; then
    TARGET_URL="${TARGET_URL}/"
fi

# --- Informações de início da varredura ---
echo -e "${BLUE}-----------------------------------------------------${NC}"
echo -e "${BLUE} Iniciando varredura em: ${TARGET_URL}${NC}"
echo -e "${BLUE} Usando wordlist: ${WORDLIST_FILE}${NC}"
echo -e "${BLUE}-----------------------------------------------------${NC}"

# --- Loop principal: Lê e processa a wordlist ---
# IFS= read -r: Garante que espaços e backslashes são lidos literalmente.
# || [[ -n "$DIR_WORD" ]]: Garante que a última linha seja lida mesmo sem newline.
while IFS= read -r DIR_WORD || [[ -n "$DIR_WORD" ]]; do
    # Remove espaços em branco (trim) do início e fim da palavra
    DIR_WORD=$(echo "$DIR_WORD" | xargs)

    # Ignora linhas vazias ou comentários (que começam com '#') na wordlist
    if [[ -z "$DIR_WORD" || "$DIR_WORD" =~ ^# ]]; then
        continue
    fi

    # Constrói a URL completa para a requisição dessa bagaça 
    FULL_URL="${TARGET_URL}${DIR_WORD}"

    # --- Realiza a requisição HTTP com curl ---
    # -s: Modo silencioso (não mostra barra de progresso ou mensagens de erro)
    # -o /dev/null: Descarta o corpo da resposta (não precisamos salvá-lo)
    # -w "%{http_code}": Formato de saída, mostra apenas o código HTTP
    # -L: Segue redirecionamentos (como 301, 302)
    # -m 5: Define um tempo limite de 5 segundos para a requisição
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -L -m 5 "$FULL_URL")

    # --- Imprime o resultado com base no código de status ---
    case "$HTTP_STATUS" in
        200) # OK
            echo -e "${GREEN}[${HTTP_STATUS}] ${FULL_URL}${NC}"
            ;;
        403) # Forbidden
            echo -e "${YELLOW}[${HTTP_STATUS}] ${FULL_URL}${NC}"
            ;;
        404) # Not Found
            echo -e "${RED}[${HTTP_STATUS}] ${FULL_URL}${NC}"
            ;;
        *)   # Outros códigos (ex: 301, 302, 500, etc.)
            echo -e "[${HTTP_STATUS}] ${FULL_URL}"
            ;;
    esac
done < "$WORDLIST_FILE" # Redireciona o arquivo da wordlist para o loop while

# --- Mensagem de conclusão da tool ---
echo -e "${BLUE}-----------------------------------------------------${NC}"
echo -e "${BLUE} Varredura concluída.${NC}"
echo -e "${BLUE}-----------------------------------------------------${NC}"
