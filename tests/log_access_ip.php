<?php
// Which address log_access.php counts a request under.
//
//     php tests/log_access_ip.php
//
// Development only: not part of server/, never uploaded.
//
// The limit is per source address. CF-Connecting-IP and X-Forwarded-For were
// read from any client, so a loader sending the same made-up address from
// every server counted as one source and the limit was gone. They are now
// believed only from the hop that sets them.

declare(strict_types=1);
define('LOG_ACCESS_LIBRARY', true);
require __DIR__ . '/../server/log_access.php';

$fails = 0;
function check(string $name, $want, $got): void {
    global $fails;
    if ($want === $got) {
        echo "ok   $name\n";
    } else {
        $fails++;
        echo "FAIL $name: want " . var_export($want, true) . ', got ' . var_export($got, true) . "\n";
    }
}

$fake = '203.0.113.50';

// The reported bypass: a client sends the headers itself.
check('a client cannot name its own address with CF-Connecting-IP', '198.51.100.7',
      client_ip_from(['REMOTE_ADDR' => '198.51.100.7', 'HTTP_CF_CONNECTING_IP' => $fake]));
check('nor with X-Forwarded-For', '198.51.100.7',
      client_ip_from(['REMOTE_ADDR' => '198.51.100.7', 'HTTP_X_FORWARDED_FOR' => $fake]));

// Through Cloudflare: the header Cloudflare sets is the client.
check('from Cloudflare (IPv4), CF-Connecting-IP', '198.51.100.7',
      client_ip_from(['REMOTE_ADDR' => '172.70.1.2', 'HTTP_CF_CONNECTING_IP' => '198.51.100.7']));
check('from Cloudflare (IPv6), CF-Connecting-IP', '2001:db8::7',
      client_ip_from(['REMOTE_ADDR' => '2606:4700:10::1', 'HTTP_CF_CONNECTING_IP' => '2001:db8::7']));
check('from Cloudflare without the header, Cloudflare itself', '172.70.1.2',
      client_ip_from(['REMOTE_ADDR' => '172.70.1.2']));
check('from Cloudflare, X-Forwarded-For is still not believed', '172.70.1.2',
      client_ip_from(['REMOTE_ADDR' => '172.70.1.2', 'HTTP_X_FORWARDED_FOR' => $fake]));
check('from Cloudflare, a header that is no address is ignored', '172.70.1.2',
      client_ip_from(['REMOTE_ADDR' => '172.70.1.2', 'HTTP_CF_CONNECTING_IP' => 'x']));

// Through a proxy on this machine: the entry it appended, the last one.
check('from our own proxy, the last X-Forwarded-For entry', '198.51.100.7',
      client_ip_from(['REMOTE_ADDR' => '127.0.0.1', 'HTTP_X_FORWARDED_FOR' => $fake . ', 198.51.100.7']));

check('no address at all', 'none', client_ip_from([]));

// The CIDR test itself, at the edges.
check('inside a /13', true, ip_in_cidr('104.23.255.255', '104.16.0.0/13'));
check('just outside a /13', false, ip_in_cidr('104.24.0.0', '104.16.0.0/13'));
check('a /29 on IPv6', true, ip_in_cidr('2a06:98c7:ffff::1', '2a06:98c0::/29'));
check('just outside it', false, ip_in_cidr('2a06:98c8::1', '2a06:98c0::/29'));
check('v4 is never inside a v6 range', false, ip_in_cidr('1.2.3.4', '2606:4700::/32'));

// A cf_ips.txt replaces the list.
check('a list given replaces the built-in one', '172.70.1.2',
      client_ip_from(['REMOTE_ADDR' => '172.70.1.2', 'HTTP_CF_CONNECTING_IP' => $fake], ['192.0.2.0/24']));

echo $fails ? "\n$fails failed\n" : "\nall passed\n";
exit($fails ? 1 : 0);
