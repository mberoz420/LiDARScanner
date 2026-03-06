<?php
/**
 * ScanWizard — Find Photo Session
 * Locates a photo session directory across root and project subfolders.
 * Returns the project name (or empty for root) so the client knows the correct path.
 *
 * GET ?session=photos_XXXXX
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

$session = basename($_GET['session'] ?? '');
if (!$session || !preg_match('/^photos_\d+_\d+$/', $session)) {
    http_response_code(400);
    echo json_encode(['error' => 'Invalid session ID']);
    exit;
}

// Check root photos/ first
if (is_dir(SCANS_PATH . '/photos/' . $session)) {
    echo json_encode(['project' => '', 'path' => '/scans/photos/' . $session]);
    exit;
}

// Search project subfolders
$dirs = glob(SCANS_PATH . '/*', GLOB_ONLYDIR);
foreach ($dirs as $dir) {
    $name = basename($dir);
    if ($name === 'photos') continue; // skip root photos dir
    if (is_dir($dir . '/photos/' . $session)) {
        echo json_encode(['project' => $name, 'path' => '/scans/' . $name . '/photos/' . $session]);
        exit;
    }
}

http_response_code(404);
echo json_encode(['error' => 'Session not found']);
