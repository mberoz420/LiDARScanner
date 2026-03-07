<?php
/**
 * ScanWizard — Configuration
 */

// ── Database ─────────────────────────────────────────────────────────────────
define('DB_HOST',    'localhost');
define('DB_NAME',    'u429345666_mberoz');
define('DB_USER',    'u429345666_mberoz');
define('DB_PASS',    'mberoZ42039@@@');
define('DB_CHARSET', 'utf8mb4');

// ── Application ──────────────────────────────────────────────────────────────
define('APP_NAME',    'ScanWizard');
define('APP_URL',     'https://scanwizard.robo-wizard.com');
define('APP_VERSION', '1.0.0');

// ── iOS App Upload Key (must match ScanServerManager.swift) ──────────────────
define('UPLOAD_API_KEY', 'ScanWizard2025Secret');

// ── Limits ───────────────────────────────────────────────────────────────────
define('MAX_UPLOAD_MB',        128);
define('MAX_SCANS_IN_MANIFEST', 200);

// ── Paths ────────────────────────────────────────────────────────────────────
define('ROOT_PATH',     dirname(__DIR__));
define('INCLUDES_PATH', __DIR__);
define('SCANS_PATH',    ROOT_PATH . '/scans');

// ── Admin ────────────────────────────────────────────────────────────────────
define('ADMIN_EMAIL', 'mberoz42@gmail.com');  // receives registration notifications

// ── Anthropic API Key (for AI door/window detection) ─────────────────────────
define('ANTHROPIC_API_KEY', '');  // fill in your key at https://console.anthropic.com

// ── Error reporting ──────────────────────────────────────────────────────────
error_reporting(0);
ini_set('display_errors', 0);

date_default_timezone_set('UTC');
