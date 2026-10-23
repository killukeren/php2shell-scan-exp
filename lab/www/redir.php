<?php
// Redirect entry point: mimics a real site where "/" 302s to a session page.
// The chain must follow the redirect and land on this script, not give up.
declare(strict_types=1);

$uri = $_SERVER['REQUEST_URI'] ?? '';

if (strpos($uri, '/landing') === false) {
    header('Location: /landing.php', true, 302);
    header('Set-Cookie: redir_test=1; path=/');
    exit;
}

session_start();
if (!isset($_SESSION['n'])) { $_SESSION['n'] = 0; }
$_SESSION['n']++;
header('Content-Type: text/plain');
echo "OK\nsid=" . session_id() . "\nhits=" . $_SESSION['n'] . "\n";
