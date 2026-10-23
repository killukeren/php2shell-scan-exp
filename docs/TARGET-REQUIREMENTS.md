# Target requirements

Every item below is required. A missing item is not a "maybe" — the chain cannot
run.

| Requirement | Why it matters | How to check |
|---|---|---|
| PHP 8.2 < 8.2.35, 8.3 < 8.3.36, 8.4 < 8.4.27, 8.5 < 8.5.12 | the bug itself | `X-Powered-By`, error page, phpinfo |
| `session.upload_progress.enabled=On` | the dangling-session primitive | see probe below |
| SAPI `mod_php` (apache2handler) | no process boundary between parse and session | `Server API` in phpinfo, or absence of FPM headers |
| Apache **prefork** | the dangling state must be reused by the same process | worker behaviour, or `mod_mpm` in phpinfo |
| a script that calls `session_start()` | `PS(id)` has to exist before it can dangle | a `PHPSESSID` cookie on a plain GET |
| `memory_limit` reachable by the payload | the OOM must actually trigger | error text, or `--calibrate-only` |

## Why `session.upload_progress` decides everything

PHP writes upload progress into the session **during multipart parsing**, before
the script runs. If the request dies from an OOM in that window, the session
structure is freed while the global still points at it. That dangling pointer is
what the reclaim request overwrites.

With `session.upload_progress=Off` there is no write during parsing, nothing
dangles, and the chain has no first step.

## Non-destructive probe

```bash
bash lab/probe_target.sh https://TARGET
```

It sends one HEAD, one GET for a random `.php`, and one 1 KB multipart POST with
`PHP_SESSION_UPLOAD_PROGRESS`. Nothing that changes server state.

What each result means:

| Observation | Meaning |
|---|---|
| `Set-Cookie: PHPSESSID=...` on a plain GET | a session starts; good sign |
| `Set-Cookie` only on the progress POST | `session_start()` exists but not on `/`; find the right endpoint |
| no `Set-Cookie` anywhere | no session machinery reachable; stop |
| 404 body contains `PHP`/`Fatal`/`Warning` | PHP handles this vhost |
| 404 body is plain Apache HTML | static vhost, or PHP elsewhere |
| `Location:` header | entry point redirects; resolve it manually first |

## Why a redirect breaks the chain

A1 must OOM on the script that holds the session. If the entry point redirects,
A1 may die on the first script while the redirect pins the remaining stages to
the second one — which never had the dangling pointer.

Resolve it yourself:

```bash
curl -sI https://TARGET/ | grep -i location
# then point the tool at the final path
python3 exploit.py -t https://TARGET/final_path.php --cmd 'id' --save /out/x
```

## Version gate

The current build flags any EOL PHP as `Vulnerable: YES`. That is wrong for this
CVE: PHP 7.x is EOL but does not contain the affected code path.

Trust these instead:

```txt
8.2.x  < 8.2.35    affected
8.3.x  < 8.3.36    affected
8.4.x  < 8.4.27    affected
8.5.x  < 8.5.12    affected
everything else    not this CVE
```

If the version is 7.x, stop. Look for a 7.x-specific bug instead.
