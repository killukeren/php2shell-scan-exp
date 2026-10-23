<?php
/**
 * Lab wp-config.php.
 *
 * DB credentials come from the environment so the same file works for the
 * compose stack and for a standalone container.
 */
define('DB_NAME',     getenv('WORDPRESS_DB_NAME')     ?: 'wordpress');
define('DB_USER',     getenv('WORDPRESS_DB_USER')     ?: 'wpuser');
define('DB_PASSWORD', getenv('WORDPRESS_DB_PASSWORD') ?: 'wppass123');
define('DB_HOST',     getenv('WORDPRESS_DB_HOST')     ?: 'db');
define('DB_CHARSET',  'utf8mb4');
define('DB_COLLATE',  '');

define('AUTH_KEY',         'p2s-lab-auth-key');
define('SECURE_AUTH_KEY',  'p2s-lab-secure-auth-key');
define('LOGGED_IN_KEY',    'p2s-lab-logged-in-key');
define('NONCE_KEY',        'p2s-lab-nonce-key');
define('AUTH_SALT',        'p2s-lab-auth-salt');
define('SECURE_AUTH_SALT', 'p2s-lab-secure-auth-salt');
define('LOGGED_IN_SALT',   'p2s-lab-logged-in-salt');
define('NONCE_SALT',       'p2s-lab-nonce-salt');

$table_prefix = 'wp_';

define('WP_DEBUG', false);
define('WP_DEBUG_LOG', false);
define('WP_DEBUG_DISPLAY', false);

// The lab is single-worker; keep cron off so it does not perturb the heap.
define('DISABLE_WP_CRON', true);

// Do NOT define WP_INSTALLING here: wp-cli sets it during `wp core install`
// and a duplicate define raises a warning and aborts the install.

if (!defined('ABSPATH')) {
    define('ABSPATH', __DIR__ . '/');
}

require_once ABSPATH . 'wp-settings.php';
