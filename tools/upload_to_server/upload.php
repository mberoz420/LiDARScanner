<?php
/**
 * ScanWizard — iOS Upload Endpoint
 * Called by the iOS app with X-API-Key header.
 * No browser session required — API key auth only.
 */
require_once 'includes/config.php';

header('Content-Type: application/json');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: POST, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type, X-API-Key');

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') { http_response_code(200); exit; }
if ($_SERVER['REQUEST_METHOD'] !== 'POST')    { respond(405, 'Method not allowed'); }

// ── Auth ─────────────────────────────────────────────────────────────────────
$key = $_SERVER['HTTP_X_API_KEY'] ?? '';
if ($key !== UPLOAD_API_KEY) { respond(401, 'Unauthorized'); }

// ── Read body ────────────────────────────────────────────────────────────────
$content = file_get_contents('php://input');
if (empty($content))                           { respond(400, 'Empty body'); }
if (strlen($content) > MAX_UPLOAD_MB * 1048576){ respond(413, 'File too large (max ' . MAX_UPLOAD_MB . ' MB)'); }

// ── Validate JSON ─────────────────────────────────────────────────────────────
$decoded = json_decode($content, true);
if (json_last_error() !== JSON_ERROR_NONE)     { respond(400, 'Invalid JSON: ' . json_last_error_msg()); }

// ── Save ──────────────────────────────────────────────────────────────────────
if (!is_dir(SCANS_PATH)) { mkdir(SCANS_PATH, 0755, true); }

// Optional project subfolder (sanitised)
$project = preg_replace('/[^a-zA-Z0-9_\- ]/', '', $_GET['project'] ?? '');
$project = trim($project);
$savePath = SCANS_PATH;
if ($project !== '') {
    $savePath = SCANS_PATH . '/' . $project;
    if (!is_dir($savePath)) { mkdir($savePath, 0755, true); }
}

// Allow caller to specify a filename (sanitised to basename, must end in .json)
$requestedName = $_GET['filename'] ?? '';
if ($requestedName !== '') {
    $requestedName = basename($requestedName);
    if (!str_ends_with($requestedName, '.json')) $requestedName .= '.json';
    // Sanitise: only allow alphanumeric, dash, underscore, dot
    $requestedName = preg_replace('/[^a-zA-Z0-9_\-.]/', '_', $requestedName);
    $filename = $requestedName;
} else {
    $filename = 'scan_' . time() . '_' . rand(1000, 9999) . '.json';
}
$filepath = $savePath . '/' . $filename;

if (file_put_contents($filepath, $content) === false) { respond(500, 'Failed to save file'); }

// ── Update manifest ───────────────────────────────────────────────────────────
$numPoints = (int)($decoded['num_points'] ?? count($decoded['points'] ?? []));
updateManifest($filename, $numPoints, $project);

$result = ['success' => true, 'filename' => $filename, 'num_points' => $numPoints];
if ($project !== '') $result['project'] = $project;
respond(200, null, $result);

// ── Helpers ───────────────────────────────────────────────────────────────────

function updateManifest(string $filename, int $numPoints, string $project = ''): void {
    $path     = SCANS_PATH . '/manifest.json';
    $manifest = file_exists($path)
        ? (json_decode(file_get_contents($path), true) ?? [])
        : [];

    $entry = [
        'filename'   => $filename,
        'timestamp'  => time(),
        'uploaded'   => date('c'),
        'num_points' => $numPoints,
    ];
    if ($project !== '') $entry['project'] = $project;

    array_unshift($manifest, $entry);

    $manifest = array_slice($manifest, 0, MAX_SCANS_IN_MANIFEST);
    file_put_contents($path, json_encode($manifest, JSON_PRETTY_PRINT));
}

function respond(int $code, ?string $error, array $extra = []): never {
    http_response_code($code);
    echo json_encode($error !== null
        ? array_merge(['success' => false, 'error' => $error], $extra)
        : $extra);
    exit;
}
