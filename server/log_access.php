<?php
// ============================================================
// XUI.ONE Multi-Tool - access logging + rate-limit endpoint
// ============================================================
// Deploy this file into the SAME directory as core_menu.sh / test_user_pass,
// which is protected by HTTP Basic auth (htpasswd). Because the whole directory
// requires authentication, this endpoint only ever runs for an already
// authenticated user: the username is taken from the authenticated session
// (PHP_AUTH_USER / Authorization header) and CANNOT be spoofed by the client.
//
// This replaces the old client-side FTP logging, which shipped the FTP write
// credentials inside the loader (readable by every user) and left the rate
// limit trivially bypassable. Here the limit is enforced server-side.
//
// See server/README.md for deployment notes (incl. the .htaccess rewrite that
// some FastCGI/cPanel setups need so PHP receives the Authorization header).

declare(strict_types=1);

// ---- Config ----
const MAX_SOURCES_24H = 2;                 // distinct servers allowed per user / window
const WINDOW_SECONDS  = 86400;             // rate-limit window (24h)
const RETENTION_DAYS  = 30;                // prune log entries older than this
define('LOG_DIR', __DIR__ . '/logs');      // per-user logs live here (kept out of the web)

// Cloudflare's ranges, https://www.cloudflare.com/ips-v4 and /ips-v6. They
// change rarely; a cf_ips.txt beside this file (one CIDR per line) replaces
// the list without touching the code.
const CLOUDFLARE_RANGES = [
    '173.245.48.0/20', '103.21.244.0/22', '103.22.200.0/22', '103.31.4.0/22',
    '141.101.64.0/18', '108.162.192.0/18', '190.93.240.0/20', '188.114.96.0/20',
    '197.234.240.0/22', '198.41.128.0/17', '162.158.0.0/15', '104.16.0.0/13',
    '104.24.0.0/14', '172.64.0.0/13', '131.0.72.0/22',
    '2400:cb00::/32', '2606:4700::/32', '2803:f800::/32', '2405:b500::/32',
    '2405:8100::/32', '2a06:98c0::/29', '2c0f:f248::/32',
];
// A reverse proxy on this machine that sets X-Forwarded-For (none by default
// on cPanel; add its address here if there is one).
const TRUSTED_PROXIES = ['127.0.0.1/32', '::1/128'];

// Loaded by tests/log_access_ip.php for its functions only.
if (defined('LOG_ACCESS_LIBRARY')) {
    return;
}

header('Content-Type: text/plain; charset=utf-8');
header('Cache-Control: no-store');

// ---- Identify the authenticated user ----
function auth_user(): string {
    if (!empty($_SERVER['PHP_AUTH_USER'])) {
        return (string) $_SERVER['PHP_AUTH_USER'];
    }
    // FastCGI/CGI (common on cPanel): the Authorization header must be passed
    // through via .htaccess (see README). Decode Basic credentials from it.
    $hdr = $_SERVER['HTTP_AUTHORIZATION'] ?? $_SERVER['REDIRECT_HTTP_AUTHORIZATION'] ?? '';
    if (stripos($hdr, 'Basic ') === 0) {
        $decoded = base64_decode(substr($hdr, 6), true);
        if ($decoded !== false && strpos($decoded, ':') !== false) {
            return explode(':', $decoded, 2)[0];
        }
    }
    return '';
}

$user = trim(auth_user());
if ($user === '' && isset($_POST['user'])) {
    // Last-resort fallback if the server never exposes the auth user. This is
    // less trustworthy (a signed-in user could name someone else), but it can
    // still only touch that name's own per-user counter.
    $user = trim((string) $_POST['user']);
}
if ($user === '') {
    http_response_code(401);
    echo "ERROR: unauthenticated\n";
    exit;
}

// Sanitize the username for use as a filename (prevents path traversal).
$safe_user = preg_replace('/[^A-Za-z0-9._-]/', '_', $user);
if ($safe_user === '' || $safe_user === '.' || $safe_user === '..') {
    http_response_code(400);
    echo "ERROR: bad user\n";
    exit;
}

// ---- Sanitize client-supplied fields (avoid log injection) ----
function clean_field(string $s, int $max = 120): string {
    $s = str_replace(['|', "\r", "\n", "\t"], ' ', $s);
    $s = trim($s);
    if (strlen($s) > $max) {
        $s = substr($s, 0, $max);
    }
    return $s === '' ? 'unknown' : $s;
}

$status = strtoupper(trim((string) ($_POST['status'] ?? 'GRANTED')));
if ($status !== 'GRANTED' && $status !== 'DENIED') {
    $status = 'GRANTED';
}
$hostname = clean_field((string) ($_POST['hostname'] ?? 'unknown'));
$os       = clean_field((string) ($_POST['os'] ?? 'unknown'));

// Optional client-reported IPs (informational only; not trusted for the limit).
$client_v4 = filter_var($_POST['client_ipv4'] ?? '', FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) ?: 'none';
$client_v6 = filter_var($_POST['client_ipv6'] ?? '', FILTER_VALIDATE_IP, FILTER_FLAG_IPV6) ?: 'none';

// ---- Determine the real client IP (works behind Cloudflare / a proxy) ----
// CF-Connecting-IP and X-Forwarded-For are headers like any other: a client
// can send them. Read as they came, one loader sending the same made-up
// address from every server it runs on counted as one source, and the
// MAX_SOURCES_24H limit was gone. They are believed only from the hop that
// sets them: CF-Connecting-IP when the connection comes from Cloudflare
// itself, X-Forwarded-For when it comes from a proxy of this host's own
// (TRUSTED_PROXIES). Anything else is REMOTE_ADDR, which cannot be forged.
function ip_in_cidr(string $ip, string $cidr): bool {
    $parts = explode('/', trim($cidr), 2);
    $net = @inet_pton($parts[0]);
    $addr = @inet_pton($ip);
    if ($net === false || $addr === false || strlen($net) !== strlen($addr)) {
        return false;
    }
    $bits = isset($parts[1]) && ctype_digit($parts[1]) ? (int) $parts[1] : strlen($net) * 8;
    $bytes = intdiv($bits, 8);
    if (substr($net, 0, $bytes) !== substr($addr, 0, $bytes)) {
        return false;
    }
    $rest = $bits % 8;
    if ($rest === 0) {
        return true;
    }
    $mask = (0xFF << (8 - $rest)) & 0xFF;
    return (ord($net[$bytes]) & $mask) === (ord($addr[$bytes]) & $mask);
}

function ip_in_any(string $ip, array $cidrs): bool {
    foreach ($cidrs as $c) {
        if ($c !== '' && ip_in_cidr($ip, $c)) {
            return true;
        }
    }
    return false;
}

function cloudflare_ranges(): array {
    $file = __DIR__ . '/cf_ips.txt';
    if (is_readable($file)) {
        $list = array_values(array_filter(array_map('trim', (array) file($file)),
            static function ($l) { return $l !== '' && $l[0] !== '#'; }));
        if ($list) {
            return $list;
        }
    }
    return CLOUDFLARE_RANGES;
}

/** The client's address from $server ($_SERVER), believing a forwarding header only from the hop that sets it. */
function client_ip_from(array $server, ?array $cf = null): string {
    $remote = (string) ($server['REMOTE_ADDR'] ?? '');
    if (!filter_var($remote, FILTER_VALIDATE_IP)) {
        return 'none';
    }
    if (ip_in_any($remote, $cf ?? cloudflare_ranges())) {
        $c = trim((string) ($server['HTTP_CF_CONNECTING_IP'] ?? ''));
        if (filter_var($c, FILTER_VALIDATE_IP)) {
            return $c;
        }
    }
    if (ip_in_any($remote, TRUSTED_PROXIES)) {
        // The last entry is the one our own proxy appended: what it saw.
        $parts = array_map('trim', explode(',', (string) ($server['HTTP_X_FORWARDED_FOR'] ?? '')));
        $last = end($parts);
        if (is_string($last) && filter_var($last, FILTER_VALIDATE_IP)) {
            return $last;
        }
    }
    return $remote;
}

function client_ip(): string {
    return client_ip_from($_SERVER);
}

// Normalize an IP to a "source" key: IPv4 -> /24, IPv6 -> /64. This tolerates
// dynamic addresses so one server that rotates its last octet (or v6 suffix)
// does not get counted as several different servers.
function source_key(string $ip): string {
    if ($ip === 'none') {
        return '';
    }
    if (filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) {
        $p = explode('.', $ip);
        return "v4:{$p[0]}.{$p[1]}.{$p[2]}.0/24";
    }
    if (filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV6)) {
        $bin = @inet_pton($ip);
        if ($bin !== false) {
            $prefix = substr($bin, 0, 8) . str_repeat("\0", 8); // first 64 bits
            $net = @inet_ntop($prefix);
            if ($net !== false) {
                return "v6:{$net}/64";
            }
        }
    }
    return '';
}

$ip      = client_ip();
$cur_key = source_key($ip);

// ---- Prepare log storage ----
if (!is_dir(LOG_DIR)) {
    @mkdir(LOG_DIR, 0755, true);
}
$log_file = LOG_DIR . '/' . $safe_user . '.log';

$now              = time();
$cutoff_window    = $now - WINDOW_SECONDS;
$cutoff_retention = $now - RETENTION_DAYS * 86400;

// ---- Atomic read-modify-write under an exclusive lock ----
$fp = fopen($log_file, 'c+');
if ($fp === false) {
    http_response_code(500);
    echo "ERROR: log storage unavailable\n";
    exit;
}
flock($fp, LOCK_EX);

$contents = stream_get_contents($fp);
$lines = ($contents === false || $contents === '') ? [] : preg_split('/\r?\n/', trim($contents));
if ($lines === false) {
    $lines = [];
}

// Parse existing entries: prune old ones and count distinct GRANTED sources
// within the window. Format: ts|date|ip|client_v4|client_v6|status|hostname|os
$kept          = [];
$window_first  = [];    // first-seen ts per source (GRANTED) in the last 24h
$window_last   = [];    // last-seen ts per source - governs when it clears
$cur_in_window = false; // has this source already logged in the window?
foreach ($lines as $line) {
    if ($line === '') {
        continue;
    }
    $f  = explode('|', $line);
    $ts = isset($f[0]) ? (int) $f[0] : 0;
    if ($ts < $cutoff_retention) {
        continue; // prune (older than retention)
    }
    $kept[] = $line;

    $row_ip     = $f[2] ?? 'none';
    $row_status = $f[5] ?? '';
    if ($ts >= $cutoff_window && $row_status === 'GRANTED') {
        $k = source_key($row_ip);
        if ($k !== '') {
            if (!isset($window_first[$k]) || $ts < $window_first[$k]) {
                $window_first[$k] = $ts;
            }
            if (!isset($window_last[$k]) || $ts > $window_last[$k]) {
                $window_last[$k] = $ts;
            }
            if ($k === $cur_key) {
                $cur_in_window = true;
            }
        }
    }
}

// ---- Rate-limit decision (server-enforced) ----
// Fail OPEN when we cannot determine this server's IP ($cur_key === ''), so a
// transient IP/proxy issue never wrongly locks out a legitimate user.
$blocked = false;
if ($status === 'GRANTED' && $cur_key !== '') {
    if (!$cur_in_window && count($window_last) >= MAX_SOURCES_24H) {
        $blocked = true;
        $status  = 'BLOCKED';
    }
}

// ---- Append the new entry and rewrite (pruned) file ----
$entry = implode('|', [
    $now,
    gmdate('Y-m-d H:i:s') . ' UTC',
    $ip,
    $client_v4,
    $client_v6,
    $status,
    $hostname,
    $os,
]);
$kept[] = $entry;

ftruncate($fp, 0);
rewind($fp);
fwrite($fp, implode("\n", $kept) . "\n");
fflush($fp);
flock($fp, LOCK_UN);
fclose($fp);

// ---- Response (first line is the machine token the bash loader parses) ----
if ($blocked) {
    echo "BLOCKED\n";
    echo 'max=' . MAX_SOURCES_24H . "\n";
    echo 'your_ip=' . $ip . "\n";
    // Per source: when it was first registered, and how long until it clears
    // (a source stops counting 24h after its most recent access).
    // Format: source=<key>|<registered UTC>|<seconds until cleared>
    foreach ($window_last as $k => $last_ts) {
        $first_ts  = $window_first[$k] ?? $last_ts;
        $clears_in = ($last_ts + WINDOW_SECONDS) - $now;
        if ($clears_in < 0) {
            $clears_in = 0;
        }
        echo 'source=' . $k . '|' . gmdate('Y-m-d H:i', $first_ts) . ' UTC|' . $clears_in . "\n";
    }
} else {
    echo "GRANTED\n";
}
