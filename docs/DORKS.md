# Candidate discovery

Queries for finding hosts that *might* run an affected PHP build. Discovery is
not authorization: a host appearing in a search engine is still someone else's
system. Confirm scope before sending anything beyond a header request.

Verified hit counts below are from Shodan, queried 2026-10-23.

---

## Shodan

### Version visible in the body

Shodan does not index the PHP patch version as a structured field
(`http.component_version:8.4` returns 0). The version string in page bodies is
what works.

```
http.html:"PHP/8.4.26"      261 hits
http.html:"PHP/8.4.15"       65 hits
http.html:"PHP/8.4.25"       58 hits
http.html:"PHP/8.3"         469 hits
```

Why it matches: the string usually comes from a phpinfo page, a debug footer, or
an error page. Those are the most useful targets anyway, because phpinfo also
exposes `session.upload_progress`, `memory_limit` and `Server API` — the three
preconditions that cannot be discovered from headers.

### Version visible in headers

```
http.headers:"X-Powered-By: PHP/8.4"
http.headers:"X-Powered-By: PHP/8.3"
product:Apache http.headers:"PHP/8.4"
```

Most hardened hosts strip `X-Powered-By`, so treat zero results here as "hidden",
not "absent".

### Narrowing to something testable

```
http.html:"PHP/8.4.26" product:Apache has_screenshot:true
http.html:"PHP/8.4.26" -http.title:"Index of"
http.html:"PHP/8.4" http.set_cookie:"PHPSESSID"
```

`http.set_cookie:"PHPSESSID"` is the most valuable filter of the set: it selects
hosts that actually start a session, which is the precondition the chain needs
and the one Shodan cannot otherwise answer.

### Scope shapers

```
-country:US -country:CN -country:RU
org:"DigitalOcean"  org:"Hetzner"  org:"Vultr"
hostname:".test"  hostname:".local"  hostname:".lab"
```

---

## Google / Bing

```
intitle:"phpinfo()" "PHP Version 8.4"
inurl:phpinfo.php "PHP Version 8.4"
"PHP Version 8.4.26" "Loaded Configuration File"
"session.upload_progress" "PHP Version 8.4"
```

---

## FOFA

```
body="PHP Version 8.4.26"
body="PHP/8.4.15"
body="session.upload_progress" && body="PHP Version 8.4"
```

## Censys

```
services.http.response.html:"PHP Version 8.4"
services.http.response.headers.server:"Apache" and services.http.response.body:"PHP/8.4"
```

---

## Triage before anything else

Raw hits are mostly useless. Filter them first:

```bash
# one host at a time
bash lab/probe_target.sh https://HOST

# or in bulk
while read -r h; do
  echo "### $h"
  bash lab/probe_target.sh "$h"
done < candidates.txt
```

Keep only hosts where step 3 or 4 prints a `PHPSESSID` cookie. Everything else
cannot run this chain regardless of PHP version.

Then, and only then, a read-only confirmation:

```bash
python3 exploit.py -t https://HOST --recon-only
```

---

## What not to do

- Do not run the exploit against hosts found this way without written
  authorization. The chain sends repeated 140 MB payloads and executes commands.
- Do not treat `Vulnerable: YES` from EOL detection as confirmation. PHP 7.x is
  EOL and not affected by this CVE.
- Do not test `.gov`, `.mil`, or critical-infrastructure hosts under any
  disclosure program whose policy forbids establishing command-line access.
