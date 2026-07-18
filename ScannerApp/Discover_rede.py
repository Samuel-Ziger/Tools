#!/usr/bin/env python3
"""
Descoberta de rede IPv4 por etapas.

Recursos:
- Exibe interfaces e rota padrão.
- Descobre hosts por ICMP e sondagem TCP.
- Considera conexão recusada como evidência de host ativo.
- Varre portas TCP com concorrência controlada.
- Salva os resultados em JSON para gerar o resumo posteriormente.
- Detecta automaticamente a rede local e aceita múltiplas sub-redes.
- Aceita intervalos de portas.

Use somente em redes próprias ou com autorização explícita.

Exemplos:
    python3 discover_rede_melhorado.py  # detecta automaticamente a rede local
    python3 discover_rede_melhorado.py --subnet 10.100.85.0/24
    python3 discover_rede_melhorado.py --subnet 10.0.0.0/24 --ports 22,80,443,8000-8010
    python3 discover_rede_melhorado.py --no-ping --workers 48
    python3 discover_rede_melhorado.py --no-skip-dead
    python3 discover_rede_melhorado.py --etapa 2 --state /tmp/rede.json
    python3 discover_rede_melhorado.py --etapa 3 --state /tmp/rede.json
    python3 discover_rede_melhorado.py -o /tmp/enum_rede.txt
"""

from __future__ import annotations

import argparse
import errno
import getpass
import ipaddress
import json
import os
import socket
import struct
import subprocess
import sys
import threading
import time
from concurrent.futures import Future, ThreadPoolExecutor, as_completed
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, TextIO


DEFAULT_PORTS = [
    20, 21, 22, 23, 25, 53, 80, 88, 110, 111,
    135, 139, 143, 179, 389, 443, 445, 465, 514,
    515, 548, 554, 587, 631, 636, 873, 902, 993,
    995, 1080, 1194, 1433, 1521, 1723, 1883, 2049,
    2222, 2375, 2376, 2483, 2484, 3000, 3128, 3268,
    3269, 3306, 3389, 3690, 4000, 4369, 4444, 5000,
    5060, 5061, 5432, 5601, 5672, 5900, 5985, 5986,
    6000, 6379, 6443, 6667, 7001, 7002, 8000, 8008,
    8080, 8081, 8088, 8181, 8443, 8888, 9000, 9090,
    9100, 9200, 9300, 9418, 10000, 11211, 15672,
    25565, 27017,
]

DEFAULT_AUTO_PREFIX = 24
DEFAULT_STATE_FILE = "enum_rede_state.json"
CONNECT_TIMEOUT = 0.8
ALIVE_TIMEOUT = 0.30
HOST_DELAY = 0.0
DEFAULT_WORKERS = 32
DEFAULT_MAX_HOSTS = 4096

# Portas usadas apenas para verificar rapidamente se o host responde.
PREFERRED_ALIVE_PORTS = [443, 80, 22, 445, 3389, 53, 8080, 8443]

COMMON_SERVICES = {
    20: "ftp-data",
    21: "ftp",
    22: "ssh",
    23: "telnet",
    25: "smtp",
    53: "dns",
    67: "dhcp-server",
    68: "dhcp-client",
    69: "tftp",
    80: "http",
    88: "kerberos",
    110: "pop3",
    111: "rpcbind",
    123: "ntp",
    135: "msrpc",
    137: "netbios-ns",
    138: "netbios-dgm",
    139: "netbios-ssn",
    143: "imap",
    161: "snmp",
    162: "snmptrap",
    179: "bgp",
    389: "ldap",
    443: "https",
    445: "smb",
    465: "smtps",
    500: "isakmp",
    514: "syslog",
    515: "printer",
    548: "afp",
    554: "rtsp",
    587: "smtp-submission",
    623: "ipmi",
    631: "ipp",
    636: "ldaps",
    873: "rsync",
    902: "vmware",
    993: "imaps",
    995: "pop3s",
    1080: "socks",
    1194: "openvpn",
    1433: "mssql",
    1521: "oracle",
    1723: "pptp",
    1883: "mqtt",
    2049: "nfs",
    2222: "ssh-alt",
    2375: "docker",
    2376: "docker-tls",
    2483: "oracle-em",
    2484: "oracle-em-tls",
    3000: "http-alt",
    3128: "squid",
    3268: "ldap-gc",
    3269: "ldaps-gc",
    3306: "mysql",
    3389: "rdp",
    3690: "svn",
    4000: "http-alt",
    4369: "epmd",
    4444: "service-alt",
    5000: "http-alt",
    5060: "sip",
    5061: "sips",
    5432: "postgresql",
    5601: "kibana",
    5672: "amqp",
    5900: "vnc",
    5985: "winrm-http",
    5986: "winrm-https",
    6000: "x11",
    6379: "redis",
    6443: "kubernetes-api",
    6667: "irc",
    7001: "weblogic",
    7002: "weblogic-tls",
    8000: "http-alt",
    8008: "http-alt",
    8080: "http-proxy",
    8081: "http-alt",
    8088: "http-alt",
    8181: "http-alt",
    8443: "https-alt",
    8888: "http-alt",
    9000: "http-alt",
    9090: "http-alt",
    9100: "jetdirect",
    9200: "elasticsearch",
    9300: "elasticsearch-transport",
    9418: "git",
    10000: "webmin",
    11211: "memcached",
    15672: "rabbitmq-management",
    25565: "minecraft",
    27017: "mongodb",
}


@dataclass(slots=True)
class InterfaceInfo:
    name: str
    state: str
    ipv4: list[str]


@dataclass(slots=True)
class HostScanResult:
    host: str
    alive: bool
    open_ports: list[int]
    tested_ports: int
    discovery_method: str
    elapsed_seconds: float


class Reporter:
    """Saída sincronizada para terminal e arquivo."""

    def __init__(self, output_path: str | None, append: bool = False) -> None:
        self._lock = threading.Lock()
        self._file: TextIO | None = None

        if output_path:
            path = Path(output_path).expanduser()
            path.parent.mkdir(parents=True, exist_ok=True)
            mode = "a" if append else "w"
            self._file = path.open(mode, encoding="utf-8")

    def log(self, line: str = "") -> None:
        with self._lock:
            print(line, flush=True)
            if self._file:
                self._file.write(line + "\n")
                self._file.flush()

    def close(self) -> None:
        if self._file:
            self._file.close()
            self._file = None

    def __enter__(self) -> "Reporter":
        return self

    def __exit__(self, exc_type, exc_value, traceback) -> None:
        self.close()


def section_header(title: str, reporter: Reporter) -> None:
    reporter.log()
    reporter.log("=" * 78)
    reporter.log(title)
    reporter.log("=" * 78)


def run_command(command: list[str], timeout: float = 5.0) -> subprocess.CompletedProcess[str] | None:
    try:
        return subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        return None


def read_interfaces() -> list[InterfaceInfo]:
    """Lê interfaces IPv4, priorizando a saída JSON do comando ip."""
    result = run_command(["ip", "-j", "-4", "addr", "show"])

    if result and result.returncode == 0:
        try:
            payload = json.loads(result.stdout)
            interfaces: list[InterfaceInfo] = []

            for item in payload:
                name = str(item.get("ifname", "?"))
                if name == "lo":
                    continue

                state = str(item.get("operstate", "UNKNOWN"))
                addresses = [
                    f"{addr['local']}/{addr['prefixlen']}"
                    for addr in item.get("addr_info", [])
                    if addr.get("family") == "inet" and addr.get("local")
                ]
                interfaces.append(InterfaceInfo(name, state, addresses))

            if interfaces:
                return interfaces
        except (json.JSONDecodeError, KeyError, TypeError, ValueError):
            pass

    # Fallback para ambientes mínimos sem o comando ip.
    interface_names: list[str] = []
    try:
        with open("/proc/net/dev", "r", encoding="utf-8", errors="replace") as file:
            for line in file.readlines()[2:]:
                if ":" not in line:
                    continue
                name = line.split(":", 1)[0].strip()
                if name and name != "lo":
                    interface_names.append(name)
    except OSError:
        pass

    ipv4_addresses: list[str] = []
    result = run_command(["hostname", "-I"])
    if result and result.returncode == 0:
        for value in result.stdout.split():
            try:
                address = ipaddress.ip_address(value)
            except ValueError:
                continue
            if isinstance(address, ipaddress.IPv4Address):
                ipv4_addresses.append(str(address))

    interfaces = []
    for index, name in enumerate(interface_names):
        state = "UNKNOWN"
        try:
            state = Path(f"/sys/class/net/{name}/operstate").read_text(encoding="utf-8").strip().upper()
        except OSError:
            pass

        # Sem getifaddrs na biblioteca padrão, não há como associar com precisão
        # cada endereço retornado por hostname -I à interface correta.
        addresses = ipv4_addresses if index == 0 else []
        interfaces.append(InterfaceInfo(name, state, addresses))

    if not interfaces and ipv4_addresses:
        interfaces.append(InterfaceInfo("(hostname -I)", "UNKNOWN", ipv4_addresses))

    return interfaces


RFC1918_NETWORKS = (
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
)

VIRTUAL_INTERFACE_PREFIXES = (
    "docker", "br-", "veth", "virbr", "podman", "cni", "flannel",
)


def is_rfc1918(address: ipaddress.IPv4Address) -> bool:
    return any(address in network for network in RFC1918_NETWORKS)


def local_ipv4_addresses(interfaces: list[InterfaceInfo]) -> list[ipaddress.IPv4Interface]:
    addresses: list[ipaddress.IPv4Interface] = []
    for interface in interfaces:
        for value in interface.ipv4:
            try:
                parsed = ipaddress.ip_interface(value)
            except ValueError:
                continue
            if isinstance(parsed, ipaddress.IPv4Interface):
                addresses.append(parsed)
    return addresses


def detect_auto_subnets(
    interfaces: list[InterfaceInfo],
    auto_prefix: int,
    include_virtual: bool,
) -> list[str]:
    """Detecta redes RFC1918 locais, usando por padrão uma fatia /24 segura."""
    detected: set[ipaddress.IPv4Network] = set()

    for interface in interfaces:
        name_lower = interface.name.lower()
        if interface.state.upper() == "DOWN":
            continue
        if not include_virtual and name_lower.startswith(VIRTUAL_INTERFACE_PREFIXES):
            continue

        for value in interface.ipv4:
            try:
                parsed = ipaddress.ip_interface(value)
            except ValueError:
                continue

            if not isinstance(parsed, ipaddress.IPv4Interface):
                continue
            if not is_rfc1918(parsed.ip):
                continue

            # Nunca amplia além da rede configurada na interface. Ex.: uma
            # interface /28 permanece /28; uma /16 vira uma fatia /24 local.
            prefix = max(parsed.network.prefixlen, auto_prefix)
            detected.add(ipaddress.ip_network(f"{parsed.ip}/{prefix}", strict=False))

    return [str(network) for network in sorted(detected, key=lambda item: (int(item.network_address), item.prefixlen))]


def warn_if_targets_are_not_local(
    reporter: Reporter,
    subnets: list[str],
    interfaces: list[InterfaceInfo],
) -> None:
    local_addresses = local_ipv4_addresses(interfaces)
    if not local_addresses:
        return

    target_networks = [ipaddress.ip_network(value, strict=False) for value in subnets]
    matching = [
        address
        for address in local_addresses
        if any(address.ip in network for network in target_networks)
    ]

    if matching:
        return

    local_text = ", ".join(str(address) for address in local_addresses)
    reporter.log()
    reporter.log("[AVISO] Nenhum endereço IPv4 local pertence às redes alvo.")
    reporter.log(f"        Endereços locais: {local_text}")
    reporter.log("        As redes podem ser roteadas, mas não são a rede local direta.")


def route_hex_to_ipv4(value: str) -> str:
    """Converte IPv4 little-endian de /proc/net/route para notação decimal."""
    packed = struct.pack("<I", int(value, 16))
    return socket.inet_ntoa(packed)


def read_routes() -> list[str]:
    """Lê as rotas IPv4 padrão usando /proc/net/route."""
    routes: list[str] = []

    try:
        with open("/proc/net/route", "r", encoding="utf-8", errors="replace") as file:
            for line in file.readlines()[1:]:
                columns = line.split()
                if len(columns) < 8:
                    continue

                interface, destination_hex, gateway_hex = columns[0], columns[1], columns[2]
                flags_hex = columns[3]
                mask_hex = columns[7]

                try:
                    destination = route_hex_to_ipv4(destination_hex)
                    gateway = route_hex_to_ipv4(gateway_hex)
                    mask = route_hex_to_ipv4(mask_hex)
                    flags = int(flags_hex, 16)
                except (ValueError, OSError, struct.error):
                    continue

                # RTF_UP = 0x0001
                if not flags & 0x0001:
                    continue

                if destination == "0.0.0.0" and mask == "0.0.0.0":
                    if gateway == "0.0.0.0":
                        routes.append(f"{interface}: rota padrão local")
                    else:
                        routes.append(f"{interface}: default via {gateway}")
    except OSError:
        pass

    return routes


def show_local_info(
    reporter: Reporter,
    subnets: list[str],
    ports: list[int],
    interfaces: list[InterfaceInfo],
    subnet_source: str,
) -> None:
    section_header("ETAPA 1 — Informações locais", reporter)
    reporter.log(f"Data UTC       : {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S %Z')}")
    reporter.log(f"Hostname       : {socket.gethostname()}")
    reporter.log(f"Usuário        : {getpass.getuser()}")
    if hasattr(os, "getuid"):
        reporter.log(f"UID            : {os.getuid()}")

    if interfaces:
        reporter.log("Interfaces     :")
        for interface in interfaces:
            addresses = ", ".join(interface.ipv4) if interface.ipv4 else "(sem IPv4 detectado)"
            reporter.log(f"  {interface.name:<16} {interface.state:<9} {addresses}")
    else:
        reporter.log("Interfaces     : não foi possível identificar")

    routes = read_routes()
    if routes:
        reporter.log("Rotas padrão   :")
        for route in routes:
            reporter.log(f"  {route}")
    else:
        reporter.log("Rotas padrão   : não foi possível identificar")

    reporter.log(f"Redes alvo     : {', '.join(subnets)}")
    reporter.log(f"Origem das redes: {subnet_source}")
    reporter.log(f"Portas padrão  : {len(ports)} portas")
    reporter.log(f"Lista de portas: {','.join(map(str, ports))}")


def tcp_probe(host: str, port: int, timeout: float) -> tuple[bool, str]:
    """Testa uma porta TCP e retorna (porta_aberta, estado)."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout)

    try:
        code = sock.connect_ex((host, port))
    except socket.timeout:
        return False, "timeout"
    except OSError as exc:
        return False, f"erro:{exc.errno or 'socket'}"
    finally:
        sock.close()

    if code == 0:
        return True, "open"
    if code == errno.ECONNREFUSED:
        return False, "closed"
    if code in {errno.EHOSTUNREACH, errno.ENETUNREACH, errno.ENETDOWN}:
        return False, "unreachable"
    if code in {errno.ETIMEDOUT, errno.EAGAIN}:
        return False, "timeout"
    if code in {errno.EACCES, errno.EPERM}:
        return False, "filtered"

    return False, f"errno:{code}"


def ping_icmp(host: str, enabled: bool = True) -> bool | None:
    """Executa um ping ICMP. Retorna None quando indisponível."""
    if not enabled:
        return None

    result = run_command(["ping", "-n", "-c", "1", "-W", "1", host], timeout=2.0)
    if result is None:
        return None
    return result.returncode == 0


def select_alive_probe_ports(ports: list[int]) -> list[int]:
    selected = [port for port in PREFERRED_ALIVE_PORTS if port in ports]
    return selected[:4] if selected else ports[:4]


def detect_host_alive(
    host: str,
    ports: list[int],
    alive_timeout: float,
    use_ping: bool,
) -> tuple[bool, str]:
    """Detecta host por ping, porta aberta ou conexão TCP recusada."""
    ping_result = ping_icmp(host, enabled=use_ping)
    if ping_result is True:
        return True, "icmp"

    for port in select_alive_probe_ports(ports):
        is_open, status = tcp_probe(host, port, alive_timeout)
        if is_open:
            return True, f"tcp/{port}:open"
        if status == "closed":
            return True, f"tcp/{port}:closed"

    if ping_result is False:
        return False, "sem-resposta"
    return False, "icmp-indisponível"


def scan_one_host(
    host: str,
    ports: list[int],
    timeout: float,
    alive_timeout: float,
    skip_dead: bool,
    use_ping: bool,
) -> HostScanResult:
    started = time.monotonic()

    alive, discovery_method = detect_host_alive(
        host,
        ports,
        alive_timeout,
        use_ping,
    )

    if skip_dead and not alive:
        return HostScanResult(
            host=host,
            alive=False,
            open_ports=[],
            tested_ports=0,
            discovery_method=discovery_method,
            elapsed_seconds=round(time.monotonic() - started, 3),
        )

    open_ports: list[int] = []
    tcp_response_seen = alive

    for port in ports:
        is_open, status = tcp_probe(host, port, timeout)
        if is_open:
            open_ports.append(port)
            tcp_response_seen = True
        elif status == "closed":
            tcp_response_seen = True

    return HostScanResult(
        host=host,
        alive=tcp_response_seen,
        open_ports=open_ports,
        tested_ports=len(ports),
        discovery_method=discovery_method,
        elapsed_seconds=round(time.monotonic() - started, 3),
    )


def format_ports(ports: list[int]) -> str:
    values = []
    for port in ports:
        service = COMMON_SERVICES.get(port)
        values.append(f"{port}/{service}" if service else str(port))
    return ", ".join(values)


def scan_subnet(
    subnet: str,
    ports: list[int],
    timeout: float,
    alive_timeout: float,
    host_delay: float,
    workers: int,
    skip_dead: bool,
    use_ping: bool,
    verbose: bool,
    max_hosts: int,
    reporter: Reporter,
) -> list[HostScanResult]:
    network = ipaddress.ip_network(subnet, strict=False)
    hosts = [str(host) for host in network.hosts()]

    if len(hosts) > max_hosts:
        raise ValueError(
            f"A rede {network} possui {len(hosts)} hosts, acima do limite {max_hosts}. "
            "Aumente --max-hosts conscientemente para continuar."
        )

    section_header(f"ETAPA 2 — Varredura de {network}", reporter)
    reporter.log(f"Hosts possíveis : {len(hosts)}")
    reporter.log(f"Portas por host : {len(ports)}")
    reporter.log(f"Workers         : {workers}")
    reporter.log(f"Pular inativos : {'sim' if skip_dead else 'não'}")
    reporter.log(f"Usar ICMP      : {'sim' if use_ping else 'não'}")

    started = time.monotonic()
    completed = 0
    results: list[HostScanResult] = []
    future_to_host: dict[Future[HostScanResult], str] = {}

    with ThreadPoolExecutor(max_workers=workers, thread_name_prefix="rede-scan") as executor:
        for host in hosts:
            future = executor.submit(
                scan_one_host,
                host,
                ports,
                timeout,
                alive_timeout,
                skip_dead,
                use_ping,
            )
            future_to_host[future] = host
            if host_delay > 0:
                time.sleep(host_delay)

        try:
            for future in as_completed(future_to_host):
                host = future_to_host[future]
                completed += 1

                try:
                    result = future.result()
                except Exception as exc:
                    reporter.log(f"[ERRO] {host}: {exc}")
                    continue

                results.append(result)

                if result.open_ports:
                    reporter.log(
                        f"[ATIVO] {result.host:<15} abertas: {format_ports(result.open_ports)} "
                        f"({result.elapsed_seconds:.3f}s)"
                    )
                elif verbose and result.alive:
                    reporter.log(
                        f"[ATIVO] {result.host:<15} sem portas abertas na lista "
                        f"({result.discovery_method})"
                    )
                elif verbose:
                    reporter.log(f"[DOWN ] {result.host:<15} {result.discovery_method}")

                if not verbose and completed % 25 == 0:
                    reporter.log(f"Progresso       : {completed}/{len(hosts)} hosts")

        except KeyboardInterrupt:
            reporter.log("\nInterrupção recebida. Cancelando tarefas pendentes...")
            for future in future_to_host:
                future.cancel()
            raise

    results.sort(key=lambda item: ipaddress.ip_address(item.host))
    elapsed = time.monotonic() - started
    active_count = sum(1 for item in results if item.alive)
    open_count = sum(1 for item in results if item.open_ports)

    reporter.log()
    reporter.log(f"Varredura concluída em {elapsed:.2f}s")
    reporter.log(f"Hosts processados          : {len(results)}")
    reporter.log(f"Hosts considerados ativos  : {active_count}")
    reporter.log(f"Hosts com portas abertas   : {open_count}")

    if active_count == 0:
        reporter.log()
        reporter.log("[AVISO] Nenhum host respondeu a ICMP ou TCP nesta varredura.")
        reporter.log("        Isso não prova que a rede esteja vazia: firewall, security group")
        reporter.log("        ou ACL podem descartar todas as sondagens.")
        if skip_dead:
            reporter.log("        Tente --no-skip-dead para testar todas as portas mesmo sem descoberta.")

    return results


def serialize_results(results_by_subnet: dict[str, list[HostScanResult]]) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "subnets": {
            subnet: [asdict(result) for result in results]
            for subnet, results in results_by_subnet.items()
        },
    }


def save_state(path: str, results_by_subnet: dict[str, list[HostScanResult]]) -> None:
    destination = Path(path).expanduser()
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".tmp")

    with temporary.open("w", encoding="utf-8") as file:
        json.dump(serialize_results(results_by_subnet), file, ensure_ascii=False, indent=2)
        file.write("\n")

    temporary.replace(destination)


def load_state(path: str) -> dict[str, list[HostScanResult]]:
    source = Path(path).expanduser()
    if not source.is_file():
        raise FileNotFoundError(f"Arquivo de estado não encontrado: {source}")

    with source.open("r", encoding="utf-8") as file:
        payload = json.load(file)

    if payload.get("schema_version") != 1 or not isinstance(payload.get("subnets"), dict):
        raise ValueError("Arquivo de estado inválido ou incompatível")

    results_by_subnet: dict[str, list[HostScanResult]] = {}
    for subnet, entries in payload["subnets"].items():
        if not isinstance(entries, list):
            raise ValueError(f"Resultados inválidos para a rede {subnet}")
        results_by_subnet[subnet] = [HostScanResult(**entry) for entry in entries]

    return results_by_subnet


def show_summary(
    results_by_subnet: dict[str, list[HostScanResult]],
    reporter: Reporter,
) -> None:
    section_header("ETAPA 3 — Resumo geral", reporter)

    total_hosts = 0
    total_alive = 0
    total_with_ports = 0

    for subnet, results in results_by_subnet.items():
        active = [result for result in results if result.alive]
        with_open_ports = [result for result in results if result.open_ports]

        total_hosts += len(results)
        total_alive += len(active)
        total_with_ports += len(with_open_ports)

        reporter.log()
        reporter.log(f"Rede: {subnet}")
        reporter.log(f"  Processados       : {len(results)}")
        reporter.log(f"  Ativos            : {len(active)}")
        reporter.log(f"  Com portas abertas: {len(with_open_ports)}")

        if with_open_ports:
            reporter.log(f"  {'HOST':<16} PORTAS ABERTAS")
            reporter.log(f"  {'-' * 62}")
            for result in with_open_ports:
                reporter.log(f"  {result.host:<16} {format_ports(result.open_ports)}")
        else:
            reporter.log("  Nenhum host com porta aberta na lista testada.")

    reporter.log()
    reporter.log("Totais:")
    reporter.log(f"  Hosts processados        : {total_hosts}")
    reporter.log(f"  Hosts considerados ativos: {total_alive}")
    reporter.log(f"  Hosts com portas abertas : {total_with_ports}")


def parse_ports(value: str) -> list[int]:
    ports: set[int] = set()

    try:
        for item in value.split(","):
            item = item.strip()
            if not item:
                continue

            if "-" in item:
                start_text, end_text = item.split("-", 1)
                start = int(start_text)
                end = int(end_text)

                if start > end:
                    raise ValueError(f"intervalo invertido: {item}")

                ports.update(range(start, end + 1))
            else:
                ports.add(int(item))
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"lista de portas inválida: {exc}") from exc

    if not ports:
        raise argparse.ArgumentTypeError("informe pelo menos uma porta")

    invalid = sorted(port for port in ports if not 1 <= port <= 65535)
    if invalid:
        preview = ", ".join(map(str, invalid[:10]))
        raise argparse.ArgumentTypeError(f"portas fora do intervalo 1-65535: {preview}")

    return sorted(ports)


def parse_subnet(value: str) -> str:
    try:
        network = ipaddress.ip_network(value, strict=False)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"sub-rede inválida: {value}") from exc

    if not isinstance(network, ipaddress.IPv4Network):
        raise argparse.ArgumentTypeError("somente redes IPv4 são suportadas")

    return str(network)


def positive_float(value: str) -> float:
    try:
        number = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("deve ser um número") from exc

    if number <= 0:
        raise argparse.ArgumentTypeError("deve ser maior que zero")
    return number


def non_negative_float(value: str) -> float:
    try:
        number = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("deve ser um número") from exc

    if number < 0:
        raise argparse.ArgumentTypeError("não pode ser negativo")
    return number


def positive_int(value: str) -> int:
    try:
        number = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("deve ser um número inteiro") from exc

    if number <= 0:
        raise argparse.ArgumentTypeError("deve ser maior que zero")
    return number


def prefix_length(value: str) -> int:
    try:
        number = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("deve ser um número inteiro") from exc

    if not 8 <= number <= 32:
        raise argparse.ArgumentTypeError("deve estar entre 8 e 32")
    return number


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Descoberta de rede IPv4 com varredura TCP e resumo persistente",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )

    parser.add_argument(
        "--subnet",
        action="append",
        type=parse_subnet,
        metavar="CIDR",
        help="Rede IPv4 para varrer; repita o argumento para várias redes",
    )
    parser.add_argument(
        "--auto-prefix",
        type=prefix_length,
        default=DEFAULT_AUTO_PREFIX,
        metavar="BITS",
        help="Prefixo usado na detecção automática; /24 evita varrer uma /16 inteira",
    )
    parser.add_argument(
        "--include-virtual",
        action="store_true",
        help="Incluir interfaces virtuais como docker0, bridges e veth na detecção automática",
    )
    parser.add_argument(
        "--ports",
        type=parse_ports,
        default=DEFAULT_PORTS,
        metavar="LISTA",
        help="Portas TCP separadas por vírgula; aceita intervalos, como 22,80,8000-8010",
    )
    parser.add_argument(
        "--timeout",
        type=positive_float,
        default=CONNECT_TIMEOUT,
        help="Timeout de conexão por porta, em segundos",
    )
    parser.add_argument(
        "--alive-timeout",
        type=positive_float,
        default=ALIVE_TIMEOUT,
        help="Timeout das sondagens rápidas de descoberta",
    )
    parser.add_argument(
        "--host-delay",
        type=non_negative_float,
        default=HOST_DELAY,
        help="Pausa entre o envio de tarefas de hosts, em segundos",
    )
    parser.add_argument(
        "--workers",
        type=positive_int,
        default=DEFAULT_WORKERS,
        help="Quantidade máxima de hosts processados simultaneamente",
    )
    parser.add_argument(
        "--max-hosts",
        type=positive_int,
        default=DEFAULT_MAX_HOSTS,
        help="Limite de hosts por rede para evitar uma varredura acidentalmente enorme",
    )
    parser.add_argument(
        "--no-ping",
        action="store_true",
        help="Não usar ICMP; detectar hosts apenas por TCP",
    )
    parser.add_argument(
        "--no-skip-dead",
        action="store_true",
        help="Testar todas as portas mesmo quando o host não responde à descoberta inicial",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Mostrar também hosts sem portas abertas e hosts sem resposta",
    )
    parser.add_argument(
        "--etapa",
        choices=["1", "2", "3", "all"],
        default="all",
        help="1=informações locais; 2=scan; 3=resumo do JSON; all=todas",
    )
    parser.add_argument(
        "--state",
        default=DEFAULT_STATE_FILE,
        help="Arquivo JSON usado para salvar ou carregar os resultados",
    )
    parser.add_argument(
        "-o",
        "--output",
        help="Salvar também a saída textual neste arquivo",
    )
    parser.add_argument(
        "--append-output",
        action="store_true",
        help="Adicionar ao arquivo de saída em vez de sobrescrevê-lo",
    )

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    interfaces = read_interfaces()
    if args.subnet:
        subnets: list[str] = args.subnet
        subnet_source = "informadas por --subnet"
    else:
        subnets = detect_auto_subnets(
            interfaces,
            auto_prefix=args.auto_prefix,
            include_virtual=args.include_virtual,
        )
        subnet_source = f"detecção automática das interfaces (/{args.auto_prefix})"

        if not subnets:
            parser.error(
                "não foi possível detectar uma rede IPv4 privada; informe --subnet REDE/CIDR"
            )

    ports: list[int] = args.ports

    try:
        with Reporter(args.output, append=args.append_output) as reporter:
            reporter.log("Use somente em redes próprias ou formalmente autorizadas.")

            if args.etapa in {"1", "all"}:
                show_local_info(
                    reporter,
                    subnets,
                    ports,
                    interfaces,
                    subnet_source,
                )
                warn_if_targets_are_not_local(reporter, subnets, interfaces)

            results_by_subnet: dict[str, list[HostScanResult]] = {}

            if args.etapa in {"2", "all"}:
                for subnet in subnets:
                    results_by_subnet[subnet] = scan_subnet(
                        subnet=subnet,
                        ports=ports,
                        timeout=args.timeout,
                        alive_timeout=args.alive_timeout,
                        host_delay=args.host_delay,
                        workers=args.workers,
                        skip_dead=not args.no_skip_dead,
                        use_ping=not args.no_ping,
                        verbose=args.verbose,
                        max_hosts=args.max_hosts,
                        reporter=reporter,
                    )

                save_state(args.state, results_by_subnet)
                reporter.log(f"Estado salvo em : {Path(args.state).expanduser()}")

            if args.etapa == "3":
                results_by_subnet = load_state(args.state)

            if args.etapa in {"3", "all"}:
                show_summary(results_by_subnet, reporter)

            section_header("FIM", reporter)
            if args.output:
                reporter.log(f"Relatório textual: {Path(args.output).expanduser()}")
            if args.etapa in {"2", "all"}:
                reporter.log(f"Resultados JSON : {Path(args.state).expanduser()}")

    except KeyboardInterrupt:
        print("\nOperação interrompida pelo usuário.", file=sys.stderr)
        return 130
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"Erro: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
