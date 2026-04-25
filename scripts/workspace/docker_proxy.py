#!/usr/bin/env python3
"""
docker_proxy.py — Filtering Docker socket proxy.

Sits between the workspace container and the rootless Docker daemon.
Intercepts POST /containers/create and blocks requests that:
  - Bind-mount host paths outside the approved project_paths list
  - Request network=host
  - Request Privileged mode
  - Add dangerous Linux capabilities

All other Docker API calls pass through unchanged, including streaming
responses, HTTP upgrades (docker exec -it), and build output.

Usage:
  docker_proxy.py <proxy-sock> <upstream-sock> [<allowed-path> ...]

Logs to <proxy-sock-dir>/docker-proxy.log and stderr.
"""

import sys
import os
import json
import logging
import socket
import threading

log = logging.getLogger(__name__)

DANGEROUS_CAPS = frozenset({
    'SYS_ADMIN', 'SYS_PTRACE', 'SYS_MODULE', 'SYS_RAWIO',
    'NET_ADMIN', 'NET_RAW', 'SYS_BOOT', 'SYS_TIME',
    'MKNOD', 'SETFCAP', 'AUDIT_CONTROL', 'MAC_ADMIN',
    'DAC_READ_SEARCH', 'LINUX_IMMUTABLE',
})

BUFSIZE = 65536


# ── Socket helpers ────────────────────────────────────────────────────────────

def recv_headers(sock):
    """Read from sock until the HTTP header block ends (\\r\\n\\r\\n).
    Returns (header_bytes, leftover_bytes) or (b'', b'') on closed connection."""
    buf = b''
    while True:
        chunk = sock.recv(BUFSIZE)
        if not chunk:
            return b'', b''
        buf += chunk
        if b'\r\n\r\n' in buf:
            idx = buf.index(b'\r\n\r\n')
            return buf[:idx], buf[idx + 4:]


def read_body(sock, header_bytes, already_read):
    """Read the full request body based on Content-Length."""
    content_length = 0
    for line in header_bytes.split(b'\r\n')[1:]:
        if line.lower().startswith(b'content-length:'):
            try:
                content_length = int(line.split(b':', 1)[1].strip())
            except ValueError:
                pass
            break

    body = already_read
    while len(body) < content_length:
        chunk = sock.recv(min(BUFSIZE, content_length - len(body)))
        if not chunk:
            break
        body += chunk
    return body[:content_length]


def pipe(src, dst):
    """Forward all data from src to dst until EOF, then half-close dst."""
    try:
        while True:
            data = src.recv(BUFSIZE)
            if not data:
                break
            dst.sendall(data)
    except Exception:
        pass
    try:
        dst.shutdown(socket.SHUT_WR)
    except Exception:
        pass


def pipe_bidirectional(client, upstream):
    """Relay data in both directions until both sides close."""
    t = threading.Thread(target=pipe, args=(upstream, client), daemon=True)
    t.start()
    pipe(client, upstream)
    t.join()


# ── Policy checks ─────────────────────────────────────────────────────────────

def is_path_allowed(host_path, allowed_paths):
    """True if host_path is under one of the allowed_paths (realpath-resolved)."""
    if not allowed_paths:
        return False
    try:
        real = os.path.realpath(host_path)
    except Exception:
        return False
    for allowed in allowed_paths:
        try:
            real_allowed = os.path.realpath(allowed)
            if real == real_allowed or real.startswith(real_allowed + os.sep):
                return True
        except Exception:
            pass
    return False


def check_create(body_bytes, allowed_paths):
    """
    Inspect a /containers/create request body.
    Returns (allowed: bool, reason: str).
    """
    try:
        spec = json.loads(body_bytes)
    except json.JSONDecodeError as exc:
        return False, f'invalid JSON body: {exc}'

    hc = spec.get('HostConfig') or {}

    if hc.get('Privileged'):
        return False, 'Privileged mode is not allowed'

    if (hc.get('NetworkMode') or '').lower() == 'host':
        return False, 'network=host is not allowed'

    cap_add = {c.upper() for c in (hc.get('CapAdd') or [])}
    bad = cap_add & DANGEROUS_CAPS
    if bad:
        return False, f'Dangerous capabilities not allowed: {", ".join(sorted(bad))}'

    # Binds entries come in two forms:
    #   - "host-path:container-path[:options]"  -> bind mount (source starts with '/')
    #   - "volume-name:container-path[:options]" -> named volume (managed by Docker,
    #                                                safe: lives under /var/lib/docker/volumes)
    # Only bind mounts need to be validated against the allowlist.
    for bind in (hc.get('Binds') or []):
        source = bind.split(':', 1)[0]
        if source.startswith('/'):
            if not is_path_allowed(source, allowed_paths):
                return False, f'Bind mount outside allowed paths: {source}'

    # Mounts: [{"Type": "bind"|"volume"|"tmpfs", "Source": "...", ...}, ...]
    # Only "bind" entries touch the host filesystem; "volume" is Docker-managed.
    for mount in (hc.get('Mounts') or []):
        if (mount.get('Type') or '') == 'bind':
            src = mount.get('Source') or mount.get('source', '')
            if not is_path_allowed(src, allowed_paths):
                return False, f'Bind mount outside allowed paths: {src}'

    return True, 'ok'


def forbidden(reason):
    body = json.dumps({'message': f'[docker-proxy] {reason}'}).encode()
    return (
        b'HTTP/1.1 403 Forbidden\r\n'
        b'Content-Type: application/json\r\n'
        b'Content-Length: ' + str(len(body)).encode() + b'\r\n'
        b'Connection: close\r\n'
        b'\r\n' + body
    )


# ── Connection handler ────────────────────────────────────────────────────────

def handle(client_sock, upstream_path, allowed_paths):
    upstream = None
    try:
        header_bytes, leftover = recv_headers(client_sock)
        if not header_bytes:
            return

        first_line = header_bytes.split(b'\r\n')[0].decode(errors='replace')
        parts = first_line.split()
        if len(parts) < 2:
            return
        method, path = parts[0], parts[1]

        is_create = method == 'POST' and '/containers/create' in path

        if is_create:
            body = read_body(client_sock, header_bytes, leftover)
            ok, reason = check_create(body, allowed_paths)
            if not ok:
                log.warning('BLOCKED %s %s — %s', method, path, reason)
                client_sock.sendall(forbidden(reason))
                return
            log.info('ALLOWED %s %s', method, path)
            upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            upstream.connect(upstream_path)
            upstream.sendall(header_bytes + b'\r\n\r\n' + body)
        else:
            upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            upstream.connect(upstream_path)
            upstream.sendall(header_bytes + b'\r\n\r\n' + leftover)

        pipe_bidirectional(client_sock, upstream)

    except Exception as exc:
        log.debug('connection error: %s', exc)
    finally:
        for s in (client_sock, upstream):
            if s:
                try:
                    s.close()
                except Exception:
                    pass


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    if len(sys.argv) < 3:
        sys.exit(f'Usage: {sys.argv[0]} <proxy-sock> <upstream-sock> [<allowed-path> ...]')

    proxy_sock_path = sys.argv[1]
    upstream_path   = sys.argv[2]
    allowed_paths   = sys.argv[3:]

    log_file = os.path.join(os.path.dirname(proxy_sock_path), 'docker-proxy.log')
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s docker-proxy %(levelname)s %(message)s',
        handlers=[
            logging.FileHandler(log_file),
            logging.StreamHandler(sys.stderr),
        ],
    )

    log.info('starting')
    log.info('  proxy socket : %s', proxy_sock_path)
    log.info('  upstream     : %s', upstream_path)
    if allowed_paths:
        for p in allowed_paths:
            log.info('  allowed path : %s', p)
    else:
        log.info('  allowed paths: (none — all bind mounts will be blocked)')

    try:
        os.unlink(proxy_sock_path)
    except FileNotFoundError:
        pass

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(proxy_sock_path)
    os.chmod(proxy_sock_path, 0o666)
    server.listen(64)
    log.info('listening')

    try:
        while True:
            conn, _ = server.accept()
            threading.Thread(
                target=handle,
                args=(conn, upstream_path, allowed_paths),
                daemon=True,
            ).start()
    except KeyboardInterrupt:
        pass
    finally:
        server.close()
        try:
            os.unlink(proxy_sock_path)
        except Exception:
            pass


if __name__ == '__main__':
    main()
