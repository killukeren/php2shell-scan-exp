<?php
// Lab page that mimics the real chain's precondition:
//
//   session_start()            -> PS(id) allocated, send_cookie armed
//   session_write_close()      -> session struct released, file NOT rewritten
//   then a memory_limit fatal  -> request dies while PS(id) is dangling
//
// The next request then reclaims that freed block with attacker-controlled
// multipart field names/values, and the forged zend_string lands on the stale
// reference. No LFI involved anywhere on this page.
declare(strict_types=1);

session_start();

if (!isset($_SESSION['n'])) {
    $_SESSION['n'] = 0;
}
$_SESSION['n']++;

// Release the session struct early. After this PS(id) is no longer owned by
// the request, so an OOM later in the request leaves it dangling.
session_write_close();

// Burn memory in a controlled way so the fatal lands after the close but
// while the request is still alive. Size comes from the request so the
// calibration sweep can dial it in.
$mb = isset($_GET['mb']) ? max(0, (int)$_GET['mb']) : 0;
if ($mb > 0) {
    $blob = str_repeat('B', $mb * 1024 * 1024);
    if (strlen($blob) === 0) {
        echo "";  // keep the optimizer from removing the allocation
    }
    unset($blob);
}

header('Content-Type: text/plain');
echo "OK\n";
echo "sid=" . session_id() . "\n";
echo "hits=" . ($_SESSION['n'] ?? 0) . "\n";
