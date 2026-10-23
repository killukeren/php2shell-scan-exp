"""Terminal output for php2shell-scan-exp.

One place for colour, so every stage looks the same and NO_COLOR is honoured
everywhere.

Palette:
    accent   cyan      banner art, target line
    brand    magenta   author line
    phase    yellow    [phase N] headers
    ok       green     successes, proofs
    warn     yellow    [!] caveats
    bad      red       [-] failures
    info     dim       [*] progress
    val      white     values after a label
"""

from __future__ import annotations

import os
import sys

# ------------------------------------------------------------------ colours

def _enabled() -> bool:
    if os.environ.get("NO_COLOR"):
        return False
    if os.environ.get("FORCE_COLOR"):
        return True
    try:
        return sys.stdout.isatty()
    except Exception:
        return False


_ON = _enabled()


def _c(code: str, s: str) -> str:
    return f"\033[{code}m{s}\033[0m" if _ON else s


def accent(s: str) -> str: return _c("36", s)
def brand(s: str) -> str:  return _c("95", s)
def phase(s: str) -> str:  return _c("33", s)
def ok(s: str) -> str:     return _c("32", s)
def warn(s: str) -> str:   return _c("33", s)
def bad(s: str) -> str:    return _c("31", s)
def info(s: str) -> str:   return _c("2", s)
def val(s: str) -> str:    return _c("97", s)
def dim(s: str) -> str:    return _c("2", s)


def label(name: str, value: str, width: int = 13) -> str:
    """Aligned `Name        : value` row used by the recon summary."""
    return f"{info(name.ljust(width))}{dim(':')} {val(value)}"


# ------------------------------------------------------------------- banner

AUTHOR = "k1llsec1337"

ART = r"""
    ____  __  ______  ___       __         ____
   / __ \/ / / / __ \|__ \ ___ / /_  ___  / / /
  / /_/ / /_/ / /_/ /__/ / __ / __ \/ _ \/ / /
 / ____/ __  / ____// __(__  / / / /  __/ / /
/_/   /_/ /_/_/    /____/____/_/ /_/\___/_/_/
"""


def banner() -> str:
    """Program header. Printed once at startup."""
    lines = [accent(ART.rstrip("\n"))]
    lines.append(dim("  " + "-" * 62))
    lines.append(
        "  " + brand("CVE-2026-109618") + dim(" / ") + brand("CVE-2026-109619")
        + dim("   |   ") + accent("PHP request-startup RCE")
    )
    lines.append(
        "  " + dim("maintained by ") + brand(AUTHOR)
        + dim("   |   upstream: ") + info("JoasASantos/php2shell-exploit")
    )
    lines.append(
        "  " + dim("authorized testing only: ") + warn("--recon-only")
        + dim(" is the safe mode")
    )
    lines.append(dim("  " + "-" * 62))
    return "\n".join(lines)


def step(n: int, name: str) -> str:
    """`[phase N] NAME` header."""
    return f"\n{phase(f'[phase {n}]')} {phase(name.upper())}"


def kv(name: str, value: str, width: int = 13) -> str:
    return label(name, value, width)


def note(msg: str) -> str:
    return f"  {info('[*]')} {msg}"


def good(msg: str) -> str:
    return f"  {ok('[+]')} {msg}"


def caveat(msg: str) -> str:
    return f"  {warn('[!]')} {msg}"


def fail(msg: str) -> str:
    return f"  {bad('[-]')} {msg}"
