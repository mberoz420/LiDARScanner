<?php
/**
 * ScanWizard — Configuration
 * Update DB_* and UPLOAD_API_KEY before deploying to Hostinger.
 */

// ── Database (create a MySQL DB in Hostinger hPanel first) ─────────────────
define('DB_HOST',    'localhost');
define('DB_NAME',    'scanwizard');      // your Hostinger DB name
define('DB_USER',    'CHANGE_ME');       // your Hostinger DB username
define('DB_PASS',    'CHANGE_ME');       // your Hostinger DB password
define('DB_CHARSET', 'utf8mb4');

// ── Application ─────────────────────────────────────────────────────────────
define('APP_NAME',       'ScanWizard');
define('APP_URL',        'https://scan-wizard.robo-wizard.com');
define('APP_VERSION',    '1.0.0');

// ── iOS App Upload Key ───────────────────────────────────────────────────────
// Must match ScanServerManager.API_KEY in the iOS app
define('UPLOAD_API_KEY', 'CHANGE_THIS_TO_YOUR_SECRET_KEY');

// ── Limits ───────────────────────────────────────────────────────────────────
define('MAX_UPLOAD_MB', 128);
define('MAX_SCANS_IN_MANIFEST', 200);

// ── Paths ────────────────────────────────────────────────────────────────────
define('ROOT_PATH',     dirname(__DIR__));
define('INCLUDES_PATH', __DIR__);
define('SCANS_PATH',    ROOT_PATH . '/scans');

// ── Error reporting (set to 0 in production) ─────────────────────────────────
error_reporting(E_ALL);
ini_set('display_errors', 0);   // never show errors to users

date_default_timezone_set('UTC');
