<?php
/**
 * ScanWizard — Serve Scan JSON
 * Streams a scan .json file by filename, authenticated by X-API-Key.
 * Used by PointCloudLabeler "Insert from Server" feature.
 */
require_once 'includes/config.php';

header('Content-Type: application/json');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Headers: X-API-Key, Content-Type');
header('Access-Control-Allow-Methods: GET, OPTIONS');

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') { exit; }

if (($_SERVER['HTTP_X_API_KEY'] ?? '') !== UPLOAD_API_KEY) {
    http_response_code(401);
    echo json_encode(['error' => 'Unauthorized']);
    exit;
}

$filename = basename($_GET['filename'] ?? '');
if (!$filename || !str_ends_with($filename, '.json') || str_starts_with($filename, 'photos_')) {
    http_response_code(400);
    echo json_encode(['error' => 'Invalid filename']);
    exit;
}

$path = SCANS_PATH . '/' . $filename;
if (!file_exists($path)) {
    http_response_code(404);
    echo json_encode(['error' => 'Scan not found']);
    exit;
}

readfile($path);
