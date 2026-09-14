# Server-side logging endpoint (`log_access.php`)

Replaces the old client-side FTP logging. The loader (`newxuione.sh`) no longer
carries any FTP credentials: it just does an authenticated `POST` to this
endpoint, and the **server** records the access and enforces the per-account
server/IP limit. This closes the leaked-credential problem and makes the rate
limit real (a client can no longer bypass it by editing the loader or the log).

## What it does

- Runs inside the Basic-auth-protected directory, so it only executes for an
  authenticated user. The username comes from the authenticated session
  (`PHP_AUTH_USER`, or the `Authorization` header) — **not** from the client.
- Determines the real client IP (`CF-Connecting-IP` → first `X-Forwarded-For` →
  `REMOTE_ADDR`), so it is correct even behind Cloudflare / a proxy.
- Enforces `MAX_SOURCES_24H` distinct servers per user per 24h. Sources are
  grouped by IPv4 `/24` and IPv6 `/64`, so a server with a dynamic address is
  not miscounted as several servers.
- Stores one append-only file per user under `logs/`, written under an
  exclusive `flock` (no lost writes on concurrent logins) and pruned of entries
  older than `RETENTION_DAYS`.

## Deploy

1. Upload `log_access.php` into the **same** directory as `core_menu.sh` and
   `test_user_pass` (i.e. served at `https://tealc.pw/stuff/xuione/new/log_access.php`).
   It is automatically covered by that directory's existing Basic auth.
2. Create the `logs/` subdirectory next to it and upload `logs/.htaccess`
   (blocks direct HTTP download of the logs). Make `logs/` writable by the PHP
   user, e.g. `chmod 755 logs` (or `775` if PHP runs as a different user/group).
   If PHP can't create it automatically, create it by hand.
3. **FastCGI / cPanel note — pass the Authorization header to PHP.** With
   PHP-FPM/CGI, `PHP_AUTH_USER` is often empty unless the directory's `.htaccess`
   forwards the header. Add these lines to the directory `.htaccess` (the one
   that already has the `AuthType Basic` / `Require valid-user`):

   ```apache
   RewriteEngine On
   RewriteCond %{HTTP:Authorization} ^(.+)$
   RewriteRule ^ - [E=HTTP_AUTHORIZATION:%1]
   ```

   Then confirm (see below) that the endpoint sees the username. Without this,
   the endpoint falls back to a POSTed `user` field, which is less trustworthy.

## Configure

Edit the constants at the top of `log_access.php`:

- `MAX_SOURCES_24H` — distinct servers allowed per user per 24h (default `2`).
- `WINDOW_SECONDS` — rate-limit window (default `86400`).
- `RETENTION_DAYS` — how long log entries are kept (default `30`).

## Verify

```bash
# GRANTED (first server)
curl -s -u USER:PASS -H 'X-Forwarded-For: 1.1.1.1' \
     --data 'status=GRANTED&hostname=srv1&os=Ubuntu%2022.04' \
     https://tealc.pw/stuff/xuione/new/log_access.php
# -> GRANTED

# A different /24 => second source, still GRANTED
curl ... -H 'X-Forwarded-For: 2.2.2.2' ...   # -> GRANTED
# A third distinct /24 => over the limit
curl ... -H 'X-Forwarded-For: 3.3.3.3' ...   # -> BLOCKED ...
# Re-using an already-registered /24 stays GRANTED
curl ... -H 'X-Forwarded-For: 1.1.1.9' ...   # -> GRANTED
```

Check that `logs/<user>.log` is created and appended, and is **not** downloadable:
`curl -u USER:PASS https://.../log_access.php/../logs/<user>.log` should be denied.

## MaxMind updater (for the Tools > MaxMind GeoIP fix)

The `MaxMind GeoIP` option in the toolkit downloads and runs `maxmind_updater.dat`
(it does an mmdb schema conversion that bash cannot). Upload it next to the other
files so the loader can fetch it:

- Upload `server/maxmind_updater.dat` to `https://tealc.pw/stuff/xuione/new/maxmind_updater.dat`
  (same Basic-auth directory as `core_menu.sh`).
- The toolkit asks the operator for their MaxMind license key (and optional
  account id) at run time and passes them to the updater via environment — the
  key is never stored in the repo.

## After deploying — decommission the FTP logging

The old FTP account is no longer used by the loader. Because its password was
shipped in the distributed loader (and is in this repo's git history), treat it
as compromised:

1. **Rotate / reset** the password of `tealcnewxuione@tealc.pw` in cPanel.
2. Restrict or delete that FTP account if nothing else uses it.
3. (Optional) migrate any historical `multitool/*.log` files to the new `logs/`.
