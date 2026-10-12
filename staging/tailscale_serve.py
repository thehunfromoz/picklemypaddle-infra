#!/usr/bin/env python3
"""Checks for staging's Tailscale Serve setup (SCRUM-38), used by tailscale.sh.

Reads the JSON that `tailscale status --json` and `tailscale serve status --json`
print, and decides whether it is safe to add (or remove) staging's HTTPS port
without touching anything else Serve already does on this machine (another app
holds :443). Funnel (public internet) is never acceptable on staging's port.

  tailscale_serve.py dnsname   STATUS.json
  tailscale_serve.py check     SERVE.json HOST PORT TARGET    -> prints "apply" or "already"
  tailscale_serve.py state     SERVE.json HOST PORT TARGET    -> prints "ours", "free" or "other"
  tailscale_serve.py verify    BEFORE.json AFTER.json HOST PORT TARGET
  tailscale_serve.py verify-off BEFORE.json AFTER.json HOST PORT

Exit 0 when fine; 1 with a one-line reason on stderr otherwise.
"""
import copy
import json
import sys


class Problem(Exception):
    pass


def load(path):
    with open(path, encoding="utf-8") as f:
        text = f.read().strip()
    return json.loads(text) if text else {}


def dnsname(status):
    if status.get("BackendState") != "Running":
        raise Problem(f"Tailscale is not running (state: {status.get('BackendState', 'unknown')}); run: sudo tailscale up")
    name = (status.get("Self") or {}).get("DNSName", "").rstrip(".")
    if not name.endswith(".ts.net"):
        raise Problem("this machine has no MagicDNS name; enable MagicDNS in the Tailscale admin console (DNS page)")
    return name


def configs(serve):
    """The persistent config plus any foreground `tailscale serve` sessions."""
    yield serve
    for fg in (serve.get("Foreground") or {}).values():
        yield fg


def proxy_of(cfg, host, port):
    """Where host:port is served to, or None if it isn't."""
    web = (cfg.get("Web") or {}).get(f"{host}:{port}")
    if not web:
        return None
    handlers = web.get("Handlers") or {}
    if set(handlers) != {"/"}:
        return "other handlers: " + ", ".join(sorted(handlers))
    return handlers["/"].get("Proxy") or "a non-proxy handler"


def funnel_on(cfg, host, port):
    return bool((cfg.get("AllowFunnel") or {}).get(f"{host}:{port}"))


def port_used(cfg, port):
    return str(port) in (cfg.get("TCP") or {})


def check(serve, host, port, target):
    for cfg in configs(serve):
        if funnel_on(cfg, host, port):
            raise Problem(f"Funnel (public internet) is switched on for port {port}; turn it off first: sudo tailscale funnel --https={port} off")
    current = proxy_of(serve, host, port)
    if current == target and port_used(serve, port):
        return "already"
    for cfg in configs(serve):
        if port_used(cfg, port) or proxy_of(cfg, host, port):
            what = proxy_of(cfg, host, port) or "a TCP forwarder"
            raise Problem(f"port {port} is already served by Tailscale ({what}); pick another TAILSCALE_HTTPS_PORT")
    return "apply"


def state(serve, host, port, target):
    """Who holds the port: staging ("ours"), nobody ("free") or something else ("other")."""
    if any(funnel_on(c, host, port) for c in configs(serve)):
        return "other"
    if proxy_of(serve, host, port) == target and port_used(serve, port):
        return "ours"
    if any(port_used(c, port) or proxy_of(c, host, port) for c in configs(serve)):
        return "other"
    return "free"


def without(serve, host, port):
    """The config with everything about host:port removed (to compare the rest)."""
    out = copy.deepcopy(serve)
    for key, sub in (("TCP", str(port)), ("Web", f"{host}:{port}"), ("AllowFunnel", f"{host}:{port}")):
        if key in out:
            out[key].pop(sub, None)
            if not out[key]:
                del out[key]
    out.pop("ETag", None)
    return out


def same_rest(before, after, host, port):
    if without(before, host, port) != without(after, host, port):
        raise Problem("Tailscale Serve settings other than staging's port changed; check: tailscale serve status")


def verify(before, after, host, port, target):
    if proxy_of(after, host, port) != target:
        raise Problem(f"https://{host}:{port} does not point at {target} (it points at {proxy_of(after, host, port)})")
    if not ((after.get("TCP") or {}).get(str(port)) or {}).get("HTTPS"):
        raise Problem(f"port {port} is not set up for HTTPS")
    if funnel_on(after, host, port):
        raise Problem(f"Funnel is on for port {port}; staging must stay private")
    same_rest(before, after, host, port)


def verify_off(before, after, host, port):
    if proxy_of(after, host, port) or port_used(after, port):
        raise Problem(f"port {port} is still served")
    same_rest(before, after, host, port)


def main(argv):
    cmd, args = argv[1], argv[2:]
    if cmd == "dnsname":
        print(dnsname(load(args[0])))
    elif cmd == "check":
        print(check(load(args[0]), args[1], int(args[2]), args[3]))
    elif cmd == "state":
        print(state(load(args[0]), args[1], int(args[2]), args[3]))
    elif cmd == "verify":
        verify(load(args[0]), load(args[1]), args[2], int(args[3]), args[4])
    elif cmd == "verify-off":
        verify_off(load(args[0]), load(args[1]), args[2], int(args[3]))
    else:
        raise Problem(f"unknown command {cmd}")


if __name__ == "__main__":
    try:
        main(sys.argv)
    except Problem as e:
        print(e, file=sys.stderr)
        sys.exit(1)
    except (IndexError, ValueError, OSError) as e:
        print(f"tailscale_serve.py: {e}", file=sys.stderr)
        sys.exit(2)
