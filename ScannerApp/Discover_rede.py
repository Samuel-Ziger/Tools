#!/usr/bin/env python3
"""
Descoberta de rede por etapas (ifconfig + nmap manual)

Uso no edge (como jose ou flavio):
    python3 discover_rede.py
    python3 discover_rede.py --subnet 10.100.85.0/24
    python3 discover_rede.py --subnet 10.0.0.0/24 --ports 22,80,443
    python3 discover_rede.py -o /tmp/enum_rede.txt

"""

from __future__ import annotations

import argparse
import ipaddress
import os
import socket
import struct
import sys
import time
from datetime import datetime, timezone


DEFAULT_PORTS = [21, 22, 80, 443, 445, 3306, 8080, 8443]
DEFAULT_SUBNETS = ["10.0.0.0/24", "10.100.85.0/24"]
CONNECT_TIMEOUT = 1.0
ALIVE_TIMEOUT = 0.35      # probe rápido antes de varrer todas as portas
HOST_DELAY = 0.03           # pausa entre hosts


def log(line: str, out) -> None:
    print(line, flush=True)
    if out:
        out.write(line + "\n")


def read_proc_net_dev() -> list[dict]:
    """Interfaces e endereços IPv4 (estilo ifconfig, sem ip/ifconfig)."""
    interfaces = []
    try:
        with open("/proc/net/dev", "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()[2:]
        for line in lines:
            if ":" not in line:
                continue
            name, stats = line.split(":", 1)
            name = name.strip()
            if name == "lo":
                continue
            ipv4 = []
            flag_path = f"/sys/class/net/{name}/flags"
            state = "UNKNOWN"
            if os.path.isfile(flag_path):
                try:
                    flags = int(open(flag_path).read().strip(), 16)
                    state = "UP" if flags & 1 else "DOWN"
                except OSError:
                    pass
            # IPv4 via getifaddrs não existe em py3 stdlib puro; tentar ip ou /proc
            interfaces.append({"name": name, "state": state, "ipv4": ipv4})
    except OSError:
        pass

    # Endereços via `hostname -I` ou parsing ip route get
    try:
        import subprocess
        r = subprocess.run(
            ["hostname", "-I"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if r.returncode == 0:
            addrs = r.stdout.strip().split()
            if interfaces and addrs:
                interfaces[0]["ipv4"] = addrs  # fallback: todos no primeiro iface
            elif addrs:
                interfaces.append({"name": "(hostname -I)", "state": "?", "ipv4": addrs})
    except Exception:
        pass

    # Tentar ip -4 addr se existir
    try:
        import subprocess
        r = subprocess.run(
            ["ip", "-4", "addr", "show"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if r.returncode == 0:
            interfaces = []
            current = None
            for line in r.stdout.splitlines():
                line = line.strip()
                if not line:
                    continue
                if line[0].isdigit() and ": " in line:
                    parts = line.split(": ")
                    current = {"name": parts[1].split("@")[0], "state": "UP" if "UP" in line else "DOWN", "ipv4": []}
                    interfaces.append(current)
                elif line.startswith("inet ") and current is not None:
                    addr = line.split()[1]
                    current["ipv4"].append(addr)
    except Exception:
        pass

    return interfaces


def read_routes() -> list[str]:
    """Rotas IPv4 via /proc/net/route."""
    routes = []
    try:
        with open("/proc/net/route", "r", encoding="utf-8", errors="replace") as f:
            for line in f.readlines()[1:]:
                cols = line.split()
                if len(cols) < 3:
                    continue
                iface, dest_hex, gw_hex = cols[0], cols[1], cols[2]
                dest = struct.unpack("<I", bytes.fromhex(dest_hex.zfill(8))[::-1])[0]
                gw = struct.unpack("<I", bytes.fromhex(gw_hex.zfill(8))[::-1])[0]
                dest_ip = socket.inet_ntoa(struct.pack(">I", dest))
                gw_ip = socket.inet_ntoa(struct.pack(">I", gw))
                if dest_ip != "0.0.0.0":
                    continue
                routes.append(f"{iface}: default via {gw_ip}" if gw else f"{iface}: local")
    except OSError:
        pass
    return routes


def section_header(title: str, out) -> None:
    log("", out)
    log("=" * 70, out)
    log(title, out)
    log("=" * 70, out)


def show_local_info(out) -> None:
    section_header("ETAPA 1 — Informação local (ifconfig / rotas)", out)
    log(f"Data UTC     : {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S')}", out)
    log(f"Hostname     : {socket.gethostname()}", out)
    try:
        log(f"Usuário      : {os.getlogin()}", out)
    except OSError:
        log(f"UID          : {os.getuid()}", out)

    ifaces = read_proc_net_dev()
    if not ifaces:
        log("Interfaces   : (não foi possível ler — instale ip ou hostname)", out)
    else:
        log("Interfaces   :", out)
        for iface in ifaces:
            ips = ", ".join(iface["ipv4"]) if iface["ipv4"] else "(sem IPv4 detectado)"
            log(f"  {iface['name']:12} {iface['state']:4}  {ips}", out)

    routes = read_routes()
    if routes:
        log("Rotas        :", out)
        for r in routes:
            log(f"  {r}", out)
    else:
        log("Rotas        : (leia /proc/net/route manualmente se necessário)", out)

    log(f"Redes alvo   : {', '.join(DEFAULT_SUBNETS)}", out)
    log(f"Portas alvo  : {DEFAULT_PORTS}", out)


def tcp_probe(host: str, port: int, timeout: float) -> tuple[bool, str]:
    """Testa uma porta TCP. Retorna (aberta, motivo)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        err = s.connect_ex((host, port))
        if err == 0:
            return True, "open"
        if err == 111:
            return False, "closed"
        if err == 113:
            return False, "filtered"
        return False, f"err={err}"
    except socket.timeout:
        return False, "timeout"
    except OSError as e:
        return False, str(e)[:40]
    finally:
        s.close()


def ping_icmp(host: str, enabled: bool = True) -> bool | None:
    """ICMP opcional; None se não disponível."""
    if not enabled:
        return None
    try:
        import subprocess
        r = subprocess.run(
            ["ping", "-c", "1", "-W", "1", host],
            capture_output=True,
            timeout=2,
        )
        return r.returncode == 0
    except Exception:
        return None


def host_alive(host: str, ports: list[int], alive_timeout: float, use_ping: bool = True) -> bool:
    """Host 'vivo' se ping OK ou alguma porta de probe responder."""
    ping = ping_icmp(host, enabled=use_ping)
    if ping is True:
        return True
    probe_ports = [p for p in (80, 22, 443) if p in ports] or ports[:2]
    for port in probe_ports:
        ok, _ = tcp_probe(host, port, alive_timeout)
        if ok:
            return True
    return False


def scan_subnet(
    subnet: str,
    ports: list[int],
    timeout: float,
    alive_timeout: float,
    host_delay: float,
    skip_dead: bool,
    use_ping: bool,
    out,
) -> list[dict]:
    """Varre host a host, porta a porta."""
    section_header(f"ETAPA 2 — Varredura {subnet} (host × porta)", out)
    net = ipaddress.ip_network(subnet, strict=False)
    results = []
    hosts_checked = 0
    hosts_alive = 0

    for ip in net.hosts():
        host = str(ip)
        hosts_checked += 1

        if skip_dead and not host_alive(host, ports, alive_timeout, use_ping):
            if hosts_checked % 20 == 0:
                log(f"  ... {hosts_checked} hosts verificados (último: {host} down)", out)
            time.sleep(host_delay)
            continue

        hosts_alive += 1
        open_ports = []
        log(f"[{host}] testando portas...", out)

        for port in ports:
            ok, status = tcp_probe(host, port, timeout)
            symbol = "ABERTA" if ok else status
            log(f"    {host}:{port:<5} -> {symbol}", out)
            if ok:
                open_ports.append(port)
            time.sleep(0.02)

        if open_ports:
            entry = {"host": host, "ports": open_ports}
            results.append(entry)
            log(f"  >> RESUMO {host}: {open_ports}", out)
        else:
            log(f"  >> RESUMO {host}: sem portas abertas na lista", out)

        time.sleep(host_delay)

    section_header(f"ETAPA 3 — Resumo {subnet}", out)
    log(f"Hosts verificados : {hosts_checked}", out)
    log(f"Hosts com resposta: {hosts_alive}", out)
    log(f"Hosts c/ portas   : {len(results)}", out)
    if results:
        log("", out)
        log(f"{'HOST':<18} PORTAS ABERTAS", out)
        log("-" * 40, out)
        for r in sorted(results, key=lambda x: ipaddress.ip_address(x["host"])):
            log(f"{r['host']:<18} {', '.join(map(str, r['ports']))}", out)
    else:
        log("(nenhum host com portas abertas na lista testada)", out)

    return results


def parse_ports(s: str) -> list[int]:
    ports = []
    for part in s.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            a, b = part.split("-", 1)
            ports.extend(range(int(a), int(b) + 1))
        else:
            ports.append(int(part))
    return sorted(set(ports))


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Descoberta de rede SYCP4 — ifconfig + scan host/porta para documentação",
    )
    parser.add_argument(
        "--subnet",
        action="append",
        metavar="CIDR",
        help="Rede para varrer (repita para várias). Padrão: 10.0.0.0/24 e 10.100.85.0/24",
    )
    parser.add_argument(
        "--ports",
        default=",".join(map(str, DEFAULT_PORTS)),
        help=f"Portas TCP separadas por vírgula (padrão: {DEFAULT_PORTS})",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=CONNECT_TIMEOUT,
        help=f"Timeout por porta em segundos (padrão: {CONNECT_TIMEOUT})",
    )
    parser.add_argument(
        "--host-delay",
        type=float,
        default=HOST_DELAY,
        help="Pausa entre hosts em segundos",
    )
    parser.add_argument(
        "--no-ping",
        action="store_true",
        help="Não usar ICMP; só TCP para detectar host vivo (mais rápido em container)",
    )
    parser.add_argument(
        "--no-skip-dead",
        action="store_true",
        help="Testar todas as portas mesmo em hosts sem resposta inicial",
    )
    parser.add_argument(
        "--etapa",
        choices=["1", "2", "3", "all"],
        default="all",
        help="1=só info local | 2=só scan | 3=só resumo (requer -o prévio) | all=tudo",
    )
    parser.add_argument(
        "--alive-timeout",
        type=float,
        default=ALIVE_TIMEOUT,
        help=f"Timeout do probe rápido de host vivo (padrão: {ALIVE_TIMEOUT})",
    )
    parser.add_argument(
        "-o", "--output",
        help="Salvar saída completa em arquivo (ex: enum_rede.txt)",
    )
    args = parser.parse_args()

    subnets = args.subnet if args.subnet else DEFAULT_SUBNETS
    ports = parse_ports(args.ports)
    etapa = args.etapa

    out_file = None
    if args.output:
        mode = "a" if etapa == "2" and os.path.isfile(args.output) else "w"
        out_file = open(args.output, mode, encoding="utf-8")

    try:
        all_results: dict[str, list[dict]] = {}

        if etapa in ("1", "all"):
            show_local_info(out_file)

        if etapa in ("2", "all"):
            for subnet in subnets:
                all_results[subnet] = scan_subnet(
                    subnet,
                    ports,
                    args.timeout,
                    args.alive_timeout,
                    args.host_delay,
                    skip_dead=not args.no_skip_dead,
                    use_ping=not args.no_ping,
                    out=out_file,
                )

        if etapa in ("3", "all") and etapa != "all":
            for subnet in subnets:
                section_header(f"ETAPA 3 — Resumo {subnet}", out_file)
                log("(execute --etapa 2 antes ou use --etapa all)", out_file)

        if etapa in ("all",):
            pass  # resumo já impresso dentro de scan_subnet

        if etapa in ("1", "2", "all"):
            section_header("FIM — Próximo passo documentação", out_file)
            log("1. Copie esta saída para pos-exploracao/ ou relatorio/", out_file)
            log("2. Para cada host com porta aberta, registre VULN / serviço em etapa separada", out_file)
            log("3. Não explore hosts até documentar este mapa", out_file)
            if args.output:
                log(f"Arquivo salvo: {args.output}", out_file)

    finally:
        if out_file:
            out_file.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
