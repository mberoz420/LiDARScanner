<?php
/**
 * ScanWizard — Project Management API
 * GET:  Returns list of project folders under scans/
 * POST: Creates a new project folder (action=create, name=...)
 */
require_once 'includes/config.php';

header('Content-Type: application/json');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Headers: X-API-Key, Content-Type');
header('Access-Control-Allow-Methods: GET, POST, OPTIONS');

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') { exit; }

if (($_SERVER['HTTP_X_API_KEY'] ?? '') !== UPLOAD_API_KEY) {
    http_response_code(401);
    echo json_encode(['error' => 'Unauthorized']);
    exit;
}

if (!is_dir(SCANS_PATH)) { mkdir(SCANS_PATH, 0755, true); }

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $input  = json_decode(file_get_contents('php://input'), true) ?? [];
    $action = $input['action'] ?? '';
    $name   = preg_replace('/[^a-zA-Z0-9_\- ]/', '', $input['name'] ?? '');
    $name   = trim($name);

    if ($action === 'create' && $name !== '') {
        $path = SCANS_PATH . '/' . $name;
        if (!is_dir($path)) {
            mkdir($path, 0755, true);
        }
        echo json_encode(['success' => true, 'name' => $name]);
    } else {
        echo json_encode(['success' => false, 'error' => 'Invalid action or name']);
    }
    exit;
}

// GET — list project folders
$projects = [];
foreach (scandir(SCANS_PATH) as $entry) {
    if ($entry === '.' || $entry === '..') continue;
    if ($entry === 'photos') continue; // skip photogrammetry folder
    if (is_dir(SCANS_PATH . '/' . $entry)) {
        $projects[] = $entry;
    }
}
sort($projects);

echo json_encode(['projects' => $projects]);
