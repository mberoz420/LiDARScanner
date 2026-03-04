<?php
/**
 * ScanWizard — Photogrammetry Photos Upload Endpoint
 *
 * Called by the iOS app with X-API-Key header.
 * Body: JSON with base64-encoded photos and camera poses.
 *
 * {
 *   "photos": [{"name": "auto_0000.jpg", "data": "<base64>"}],
 *   "camera_poses": [[...16 floats...], ...]
 * }
 *
 * Creates /scans/photos/SESSION_ID/ with:
 *   - auto_0000.jpg, auto_0001.jpg, …
 *   - transforms.json (camera_poses array)
 *   - session.json (metadata)
 *
 * Updates /scans/manifest.json with type=photogrammetry.
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

// ── Read + validate body ──────────────────────────────────────────────────────
$content = file_get_contents('php://input');
if (empty($content))                            { respond(400, 'Empty body'); }
if (strlen($content) > MAX_UPLOAD_MB * 1048576) { respond(413, 'Payload too large (max ' . MAX_UPLOAD_MB . ' MB)'); }

$decoded = json_decode($content, true);
if (json_last_error() !== JSON_ERROR_NONE)      { respond(400, 'Invalid JSON: ' . json_last_error_msg()); }

$photos      = $decoded['photos']       ?? [];
$cameraPoses = $decoded['camera_poses'] ?? [];

if (empty($photos)) { respond(400, 'No photos in payload'); }

// ── Create session directory ──────────────────────────────────────────────────
$sessionId   = 'photos_' . time() . '_' . rand(1000, 9999);
$photosBase  = SCANS_PATH . '/photos';
$sessionPath = $photosBase . '/' . $sessionId;

if (!is_dir($photosBase)) { mkdir($photosBase, 0755, true); }
if (!mkdir($sessionPath, 0755, true)) { respond(500, 'Failed to create session directory'); }

// ── Save JPEG photos ──────────────────────────────────────────────────────────
$savedCount = 0;
foreach ($photos as $photo) {
    $name   = basename($photo['name'] ?? '');
    $base64 = $photo['data'] ?? '';

    if (empty($name) || empty($base64)) { continue; }

    // Only accept JPEG filenames
    if (!preg_match('/^auto_\d{4}\.jpg$/', $name)) { continue; }

    $data = base64_decode($base64, true);
    if ($data === false) { continue; }

    if (file_put_contents($sessionPath . '/' . $name, $data) !== false) {
        $savedCount++;
    }
}

if ($savedCount === 0) { respond(500, 'No photos could be saved'); }

// ── Save transforms.json ──────────────────────────────────────────────────────
if (!empty($cameraPoses)) {
    $transforms = ['camera_poses' => $cameraPoses];

    // Per-frame camera intrinsics [fx, fy, cx, cy] (landscape pixels)
    $intrinsics = $decoded['intrinsics'] ?? [];
    if (!empty($intrinsics)) {
        $transforms['intrinsics'] = $intrinsics;
    }

    // Landscape image resolution [W, H] used for the projection math
    $imageSize = $decoded['image_size'] ?? [];
    if (!empty($imageSize)) {
        $transforms['image_size'] = $imageSize;
    }

    file_put_contents($sessionPath . '/transforms.json',
                      json_encode($transforms, JSON_PRETTY_PRINT));
}

// ── Save pointcloud.json (LiDAR geometry captured during same session) ────────
$pointCloud = $decoded['point_cloud'] ?? null;
if (!empty($pointCloud)) {
    file_put_contents($sessionPath . '/pointcloud.json',
                      json_encode($pointCloud, JSON_PRETTY_PRINT));
}

// ── Save session.json ─────────────────────────────────────────────────────────
$sessionMeta = [
    'session_id'  => $sessionId,
    'photo_count' => $savedCount,
    'pose_count'  => count($cameraPoses),
    'created'     => date('c'),
    'uploaded'    => date('c'),
];
file_put_contents($sessionPath . '/session.json',
                  json_encode($sessionMeta, JSON_PRETTY_PRINT));

// ── Update global manifest ────────────────────────────────────────────────────
updateManifest($sessionId, $savedCount);

respond(200, null, [
    'success'     => true,
    'session_id'  => $sessionId,
    'photo_count' => $savedCount,
]);

// ── Helpers ───────────────────────────────────────────────────────────────────

function updateManifest(string $sessionId, int $photoCount): void {
    $path     = SCANS_PATH . '/manifest.json';
    $manifest = file_exists($path)
        ? (json_decode(file_get_contents($path), true) ?? [])
        : [];

    array_unshift($manifest, [
        'filename'    => $sessionId,
        'type'        => 'photogrammetry',
        'timestamp'   => time(),
        'uploaded'    => date('c'),
        'photo_count' => $photoCount,
    ]);

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
