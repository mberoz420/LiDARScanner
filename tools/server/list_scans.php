<?php
/**
 * ScanWizard — List Scans API
 * GET:  Returns scan list. Optional ?project= to filter by project folder.
 *       Without ?project, returns all scans (root + all projects).
 *       Includes both JSON point clouds and photo sessions.
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

/**
 * Scan a directory for JSON point cloud files.
 */
function collectJsonScans(string $dir, string $project, array &$scans): void {
    if (!is_dir($dir)) return;
    foreach (scandir($dir) as $f) {
        if ($f === '.' || $f === '..') continue;
        $path = $dir . '/' . $f;
        if (is_dir($path)) continue;
        if (!str_ends_with($f, '.json') || $f === 'manifest.json') continue;
        if (str_starts_with($f, 'photos_')) continue;
        $data = json_decode(file_get_contents($path), true);
        $numPoints = (int)($data['num_points'] ?? count($data['points'] ?? []));
        $scans[] = [
            'filename'   => $f,
            'project'    => $project,
            'type'       => 'scan',
            'timestamp'  => filemtime($path),
            'uploaded'   => date('c', filemtime($path)),
            'num_points' => $numPoints,
        ];
    }
}

/**
 * Scan a photos/ directory for photo sessions.
 */
function collectPhotoSessions(string $photosDir, string $project, array &$scans): void {
    if (!is_dir($photosDir)) return;
    foreach (scandir($photosDir) as $d) {
        if ($d === '.' || $d === '..') continue;
        $sessionPath = $photosDir . '/' . $d;
        if (!is_dir($sessionPath)) continue;
        if (!str_starts_with($d, 'photos_')) continue;

        // Read session.json for metadata
        $metaPath = $sessionPath . '/session.json';
        $photoCount = 0;
        $created = filemtime($sessionPath);
        if (file_exists($metaPath)) {
            $meta = json_decode(file_get_contents($metaPath), true);
            $photoCount = (int)($meta['photo_count'] ?? 0);
            if (!empty($meta['created'])) {
                $created = strtotime($meta['created']) ?: $created;
            }
        } else {
            // Count JPEGs if no session.json
            $photoCount = count(glob($sessionPath . '/auto_*.jpg'));
        }

        $hasPointCloud = file_exists($sessionPath . '/pointcloud.json');

        $scans[] = [
            'filename'    => $d,
            'project'     => $project,
            'type'        => 'photos',
            'timestamp'   => $created,
            'uploaded'    => date('c', $created),
            'photo_count' => $photoCount,
            'has_pointcloud' => $hasPointCloud,
        ];
    }
}

if ($project !== '') {
    // Specific project
    $dir = SCANS_PATH . '/' . $project;
    collectJsonScans($dir, $project, $scans);
    collectPhotoSessions($dir . '/photos', $project, $scans);
} else if ($rootOnly) {
    // Root only
    collectJsonScans(SCANS_PATH, '', $scans);
    collectPhotoSessions(SCANS_PATH . '/photos', '', $scans);
} else {
    // ALL: root + project subfolders
    collectJsonScans(SCANS_PATH, '', $scans);
    collectPhotoSessions(SCANS_PATH . '/photos', '', $scans);

    foreach (scandir(SCANS_PATH) as $dir) {
        if ($dir === '.' || $dir === '..' || $dir === 'photos') continue;
        $dirPath = SCANS_PATH . '/' . $dir;
        if (!is_dir($dirPath)) continue;
        collectJsonScans($dirPath, $dir, $scans);
        collectPhotoSessions($dirPath . '/photos', $dir, $scans);
    }
}

// Sort by timestamp descending (newest first)
usort($scans, fn($a, $b) => ($b['timestamp'] ?? 0) - ($a['timestamp'] ?? 0));
$scans = array_slice($scans, 0, MAX_SCANS_IN_MANIFEST);

echo json_encode(['scans' => $scans]);
