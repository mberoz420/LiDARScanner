<?php
/**
 * ScanWizard — Protected Labeler Access
 * Checks user session before serving PointCloudLabeler.html.
 * Unauthenticated users are redirected to login.php.
 */
session_start();
require_once 'includes/config.php';

if (!isset($_SESSION['user_id'])) {
    header('Location: login.php?redirect=' . urlencode($_SERVER['REQUEST_URI']));
    exit;
}

// Serve the labeler HTML
readfile(__DIR__ . '/PointCloudLabeler.html');
