<?php
/**
 * Plugin Name: P2S Session Probe (OFF)
 * Description: Control plugin. Does NOT call session_start(). Exists so the
 *              lab can prove that WordPress core alone has no PS(id), and
 *              therefore nothing for the chain to dangle.
 * Version:     1.0
 * Author:      lab
 */

if (!defined('ABSPATH')) {
    exit;
}

// Intentionally empty: no session, no PHPSESSID cookie, no precondition.
