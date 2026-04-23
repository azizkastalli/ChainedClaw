#!/usr/bin/env python3
"""
egress_proxy.py — Transparent HTTP/HTTPS egress filter for AGENT_USER.

Runs as root on the target host. iptables REDIRECT routes AGENT_USER's
port 80 and 443 outbound connections here before they leave the machine.

For HTTPS: reads the TLS SNI from the ClientHello without decrypting —
TLS is end-to-end between the client and the real server. The proxy just
peeks at the hostname, allows or blocks, then tunnels the raw bytes through.

For HTTP: reads the Host header.

Subdomain matching: "quay.io" in allowed_domains also permits
"cdn01.quay.io", covering CDN-backed registries without enumerating
their subdomains.

Usage:
  egress_proxy.py <listen-port> <config-json-path>
"""

import sys
import os
import json
import socket
import struct
import threading
import logging

PROXY_TIMEOUT = 10      # seconds: upstream connect + initial recv
BUFSIZE       = 65536

# linux/netfilter_ipv4.h
SOL_IP          = 0
SO_ORIGINAL_DST = 80

log = logging.getLogger(__name__)


# ── Config ────────────────────────────────────────────────────────────────────

def load_allowed(config_path):
    """
    Return normalised bare domains from config.json allowed_domains.
    '*.quay.io' and 'quay.io' are both stored as 'quay.io'; is_allowed()
    always tests the hostname against the domain AND all its subdomains.
    """
    try:
        with open(config_path) as f:
            c = json.load(f)
        return [d.lower().lstrip('*.').strip('.') for d in c.get('allowed_domains', []) if d]
    except Exception as exc:
        log.error('Cannot load config %s: %s', config_path, exc)
        return []


def is_allowed(hostname, allowed):
    h = hostname.lower().rstrip('.')
    for domain in allowed:
        if h == domain or h.endswith('.' + domain):
            return True
    return False


# ── Original destination ──────────────────────────────────────────────────────

def original_dst(sock):
    """Return (ip, port) of the connection before iptables REDIRECT, or (None, None)."""
    try:
        raw  = sock.getsockopt(SOL_IP, SO_ORIGINAL_DST, 16)
        port = struct.unpack('>H', raw[2:4])[0]
        ip   = socket.inet_ntoa(raw[4:8])
        return ip, port
    except OSError:
        return None, None


# ── TLS ClientHello reader ────────────────────────────────────────────────────

def read_client_hello(sock):
    """
    Read bytes until we have the full TLS ClientHello record (or give up at 16 KB).
    Returns the raw bytes; caller must forward them to upstream unchanged.
    """
    sock.settimeout(PROXY_TIMEOUT)
    buf = b''
    while len(buf) < 16384:
        try:
            chunk = sock.recv(4096)
        except socket.timeout:
            break
        if not chunk:
            break
        buf += chunk
        # Stop once we have the complete record declared in the 5-byte header.
        if len(buf) >= 5 and buf[0] == 0x16:
            rec_len = struct.unpack('>H', buf[3:5])[0]
            if len(buf) >= 5 + rec_len:
                break
        elif len(buf) >= 5 and buf[0] != 0x16:
            break   # not TLS — stop reading
    return buf


def extract_sni(data):
    """Parse a TLS ClientHello and return the SNI hostname string, or None."""
    try:
        if len(data) < 5 or data[0] != 0x16:
            return None
        rec_len = struct.unpack('>H', data[3:5])[0]
        if len(data) < 5 + rec_len:
            return None

        pos = 5
        if data[pos] != 0x01:                           # must be ClientHello
            return None
        pos += 4                                         # type(1) + length(3)
        pos += 2 + 32                                    # client_version + random

        sid_len = data[pos]; pos += 1 + sid_len          # session_id
        cs_len  = struct.unpack('>H', data[pos:pos+2])[0]
        pos += 2 + cs_len                                # cipher_suites
        cm_len  = data[pos]; pos += 1 + cm_len           # compression_methods

        if pos + 2 > len(data):
            return None
        ext_end = pos + 2 + struct.unpack('>H', data[pos:pos+2])[0]
        pos += 2

        while pos + 4 <= ext_end:
            ext_type = struct.unpack('>H', data[pos:pos+2])[0]
            ext_len  = struct.unpack('>H', data[pos+2:pos+4])[0]
            pos += 4
            if ext_type == 0:                            # server_name (SNI)
                if pos + 5 <= ext_end:
                    name_len = struct.unpack('>H', data[pos+3:pos+5])[0]
                    return data[pos+5: pos+5+name_len].decode('ascii', errors='replace')
            pos += ext_len
    except Exception:
        pass
    return None


# ── HTTP Host header reader ───────────────────────────────────────────────────

def read_http_headers(sock):
    sock.settimeout(PROXY_TIMEOUT)
    buf = b''
    while b'\r\n\r\n' not in buf and len(buf) < 16384:
        try:
            chunk = sock.recv(4096)
        except socket.timeout:
            break
        if not chunk:
            break
        buf += chunk
    return buf


def extract_host(data):
    try:
        for line in data.decode('latin-1').split('\r\n')[1:]:
            if line.lower().startswith('host:'):
                return line[5:].strip().split(':')[0].strip()
    except Exception:
        pass
    return None


# ── Bidirectional tunnel ──────────────────────────────────────────────────────

def _pump(src, dst):
    try:
        while True:
            d = src.recv(BUFSIZE)
            if not d:
                break
            dst.sendall(d)
    except Exception:
        pass
    finally:
        try: dst.shutdown(socket.SHUT_WR)
        except Exception: pass


def tunnel(client, upstream):
    t = threading.Thread(target=_pump, args=(upstream, client), daemon=True)
    t.start()
    _pump(client, upstream)
    t.join(timeout=60)


# ── Connection handler ────────────────────────────────────────────────────────

def handle(client, allowed):
    orig_ip, orig_port = original_dst(client)
    upstream = None
    try:
        client.settimeout(PROXY_TIMEOUT)
        peek = client.recv(1, socket.MSG_PEEK)
        if not peek:
            return

        if peek == b'\x16':             # TLS record type: handshake
            buf      = read_client_hello(client)
            hostname = extract_sni(buf)
            port     = orig_port or 443
            proto    = 'HTTPS'
        else:
            buf      = read_http_headers(client)
            hostname = extract_host(buf)
            port     = orig_port or 80
            proto    = 'HTTP'

        if not hostname:
            log.warning('BLOCKED %s — no hostname (orig %s:%s)', proto, orig_ip, orig_port)
            return

        if not is_allowed(hostname, allowed):
            log.warning('BLOCKED %s %s (orig %s:%s)', proto, hostname, orig_ip, port)
            if proto == 'HTTP':
                try:
                    client.sendall(
                        b'HTTP/1.1 403 Forbidden\r\n'
                        b'Content-Length: 0\r\nConnection: close\r\n\r\n'
                    )
                except Exception:
                    pass
            return

        log.info('ALLOWED %s %s', proto, hostname)
        upstream = socket.create_connection((orig_ip or hostname, port), timeout=PROXY_TIMEOUT)
        upstream.sendall(buf)
        tunnel(client, upstream)

    except Exception as exc:
        log.debug('handler error: %s', exc)
    finally:
        try: client.close()
        except Exception: pass
        if upstream:
            try: upstream.close()
            except Exception: pass


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    if len(sys.argv) < 3:
        sys.exit(f'Usage: {sys.argv[0]} <port> <config.json>')

    port        = int(sys.argv[1])
    config_path = sys.argv[2]
    log_file    = os.path.join(os.path.dirname(os.path.abspath(config_path)),
                               'egress-proxy.log')

    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s %(levelname)s %(message)s',
        handlers=[logging.FileHandler(log_file), logging.StreamHandler()],
    )

    allowed = load_allowed(config_path)
    log.info('Egress proxy listening on 127.0.0.1:%d', port)
    log.info('Allowed domains (%d): %s', len(allowed), ', '.join(allowed))

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(('127.0.0.1', port))
    srv.listen(256)

    while True:
        try:
            conn, _ = srv.accept()
            threading.Thread(target=handle, args=(conn, allowed), daemon=True).start()
        except Exception as exc:
            log.error('accept error: %s', exc)


if __name__ == '__main__':
    main()
