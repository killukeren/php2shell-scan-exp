<?php
// Session-enabled entry point.
//
// The dimas chain does NOT need an LFI here - it needs session machinery:
//   1. session_start() so PS(id) exists and send_cookie can be set
//   2. session.upload_progress.enabled=On so PHP_SESSION_UPLOAD_PROGRESS
//      writes into the session during POST parsing
//   3. an OOM (memory_limit fatal) that lands *after* the session is entered
//      but *before* request startup completes, leaving PS(id) dangling
//
// Once PS(id) dangles, the next request reclaims that freed block with
// attacker-controlled multipart field names/values, and the forged
// zend_string lands on the stale reference.
declare(strict_types=1);

session_start();

// Touch the session so a session file/entry is actually created even on a
// cold request (an empty session can be optimized away on some builds).
if (!isset($_SESSION['n'])) {
    $_SESSION['n'] = 0;
}
$_SESSION['n']++;

header('Content-Type: text/plain');
echo "OK\n";
echo "sid=" . session_id() . "\n";
echo "hits=" . $_SESSION['n'] . "\n";
