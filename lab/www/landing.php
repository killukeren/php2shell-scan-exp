<?php
// Target of the 302 in redir.php. Session-enabled so the chain has PS(id).
declare(strict_types=1);

session_start();
if (!isset($_SESSION['n'])) { $_SESSION['n'] = 0; }
$_SESSION['n']++;

header('Content-Type: text/plain');
echo "OK\nsid=" . session_id() . "\nhits=" . $_SESSION['n'] . "\n";
