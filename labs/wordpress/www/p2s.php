<?php
// Minimal session-enabled page, dropped into the WordPress container to
// separate "PHP in this container is fine" from "WordPress bootstrap breaks
// the heap layout".
declare(strict_types=1);

session_start();
if (!isset($_SESSION['n'])) {
    $_SESSION['n'] = 0;
}
$_SESSION['n']++;

header('Content-Type: text/plain');
echo "OK\n";
echo "sid=" . session_id() . "\n";
echo "hits=" . $_SESSION['n'] . "\n";
