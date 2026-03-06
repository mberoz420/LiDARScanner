<?php
/**
 * ScanWizard — List Scans API
 * Returns the scan manifest as JSON, authenticated by X-API-Key.
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

$manifestPath = SCANS_PATH . '/manifest.json';
$scans = file_exists($manifestPath)
    ? (json_decode(file_get_contents($manifestPath), true) ?? [])
    : [];

// Only return LiDAR point-cloud scans (not photo sessions)
$scans = array_values(array_filter($scans, fn($s) =>
    isset($s['filename']) && str_ends_with($s['filename'], '.json')
    && !str_starts_with($s['filename'], 'photos_')
));

echo json_encode(['scans' => $scans]);
