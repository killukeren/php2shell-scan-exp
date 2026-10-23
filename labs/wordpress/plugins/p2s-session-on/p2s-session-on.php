<?php
/**
 * Plugin Name: P2S Session Probe (ON)
 * Description: Calls session_start() on every front-end request. This is the
 *              precondition the php2shell chain needs: a live PS(id) that an
 *              OOM during request startup can leave dangling. Used to test
 *              whether WordPress can be affected when a plugin uses PHP
 *              sessions.
 * Version:     1.0
 * Author:      lab
 */

if (!defined('ABSPATH')) {
    exit;
}

add_action('init', function () {
    if (PHP_SAPI !== 'apache2handler') {
        return;
    }
    if (session_status() !== PHP_SESSION_ACTIVE) {
        @session_start();
    }
    // Touch it so a session file is actually created, not optimised away.
    if (isset($_SESSION['p2s'])) {
        $_SESSION['p2s']++;
    } else {
        $_SESSION['p2s'] = 1;
    }
}, 1);
