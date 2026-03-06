<?php
/**
 * ScanWizard — List Scans API
 * GET:  Returns scan list. Optional ?project= to filter by project folder.
 *       Without ?project, returns all scans (root + all projects).
 * Used by PointCloudLabeler "Open from Server" and "Insert from Server".
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

$projectRaw = $_GET['project'] ?? '';
$rootOnly = ($projectRaw === '__root__');
$project = $rootOnly ? '' : preg_replace('/[^a-zA-Z0-9_\- ]/', '', $projectRaw);
$project = trim($project);

$scans = [];

if ($project !== '') {
    // List scans in a specific project folder
    $dir = SCANS_PATH . '/' . $project;
    if (is_dir($dir)) {
        foreach (scandir($dir) as $f) {
            if ($f === '.' || $f === '..') continue;
            if (!str_ends_with($f, '.json')) continue;
            if (str_starts_with($f, 'photos_')) continue;
            $path = $dir . '/' . $f;
            $size = filesize($path);
            $data = json_decode(file_get_contents($path), true);
            $numPoints = (int)($data['num_points'] ?? count($data['points'] ?? []));
            $scans[] = [
                'filename'   => $f,
                'project'    => $project,
                'timestamp'  => filemtime($path),
                'uploaded'   => date('c', filemtime($path)),
                'num_points' => $numPoints,
            ];
        }
    }
} else if ($rootOnly) {
    // List only root-level scans (no project)
    foreach (scandir(SCANS_PATH) as $f) {
        if ($f === '.' || $f === '..' || $f === 'photos') continue;
        $path = SCANS_PATH . '/' . $f;
        if (is_dir($path)) continue;
        if (!str_ends_with($f, '.json') || $f === 'manifest.json') continue;
        if (str_starts_with($f, 'photos_')) continue;
        $data = json_decode(file_get_contents($path), true);
        $numPoints = (int)($data['num_points'] ?? count($data['points'] ?? []));
        $scans[] = [
            'filename'   => $f,
            'project'    => '',
            'timestamp'  => filemtime($path),
            'uploaded'   => date('c', filemtime($path)),
            'num_points' => $numPoints,
        ];
    }
} else {
    // List ALL scans: root + project subfolders
    // Root scans
    foreach (scandir(SCANS_PATH) as $f) {
        if ($f === '.' || $f === '..' || $f === 'photos') continue;
        $path = SCANS_PATH . '/' . $f;
        if (is_dir($path)) continue; // skip directories
        if (!str_ends_with($f, '.json') || $f === 'manifest.json') continue;
        if (str_starts_with($f, 'photos_')) continue;
        $data = json_decode(file_get_contents($path), true);
        $numPoints = (int)($data['num_points'] ?? count($data['points'] ?? []));
        $scans[] = [
            'filename'   => $f,
            'project'    => '',
            'timestamp'  => filemtime($path),
            'uploaded'   => date('c', filemtime($path)),
            'num_points' => $numPoints,
        ];
    }
    // Project subfolders
    foreach (scandir(SCANS_PATH) as $dir) {
        if ($dir === '.' || $dir === '..' || $dir === 'photos') continue;
        $dirPath = SCANS_PATH . '/' . $dir;
        if (!is_dir($dirPath)) continue;
        foreach (scandir($dirPath) as $f) {
            if ($f === '.' || $f === '..') continue;
            if (!str_ends_with($f, '.json')) continue;
            if (str_starts_with($f, 'photos_')) continue;
            $path = $dirPath . '/' . $f;
            $data = json_decode(file_get_contents($path), true);
            $numPoints = (int)($data['num_points'] ?? count($data['points'] ?? []));
            $scans[] = [
                'filename'   => $f,
                'project'    => $dir,
                'timestamp'  => filemtime($path),
                'uploaded'   => date('c', filemtime($path)),
                'num_points' => $numPoints,
            ];
        }
    }
}

// Sort by timestamp descending (newest first)
usort($scans, fn($a, $b) => ($b['timestamp'] ?? 0) - ($a['timestamp'] ?? 0));
$scans = array_slice($scans, 0, MAX_SCANS_IN_MANIFEST);

echo json_encode(['scans' => $scans]);
