<?php
/**
 * ScanWizard — AI Door/Window Detection
 * Calls Claude claude-haiku-4-5-20251001 vision API with a session photo.
 * Returns detected bounding boxes for doors and windows.
 *
 * POST body (JSON): { "session_id": "photos_...", "photo_index": 0 }
 * Header: X-API-Key must match UPLOAD_API_KEY
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

// ── Validate Anthropic key configured ────────────────────────────────────────
if (empty(ANTHROPIC_API_KEY)) { respond(503, 'Anthropic API key not configured on server'); }

// ── Parse request ─────────────────────────────────────────────────────────────
$body = json_decode(file_get_contents('php://input'), true);
if (!$body) { respond(400, 'Invalid JSON'); }

$sessionId   = preg_replace('/[^a-zA-Z0-9_\-]/', '', $body['session_id']   ?? '');
$photoIndex  = (int)($body['photo_index'] ?? 0);

if (empty($sessionId)) { respond(400, 'Missing session_id'); }

// ── Load photo ────────────────────────────────────────────────────────────────
$photoPath = SCANS_PATH . '/photos/' . $sessionId . '/' . sprintf('auto_%04d.jpg', $photoIndex);
if (!file_exists($photoPath)) { respond(404, 'Photo not found: ' . basename($photoPath)); }

// ── Downsample photo to 800px wide before sending to Claude ──────────────────
// Full-res iPhone photos (~4032×3024) cost ~10× more in image tokens than needed.
// 800px is plenty for detecting door/window bounding boxes.
$src = imagecreatefromjpeg($photoPath);
if ($src !== false) {
    $srcW = imagesx($src);
    $srcH = imagesy($src);
    $maxW = 800;
    if ($srcW > $maxW) {
        $dstW = $maxW;
        $dstH = (int)round($srcH * $maxW / $srcW);
        $dst  = imagecreatetruecolor($dstW, $dstH);
        imagecopyresampled($dst, $src, 0, 0, 0, 0, $dstW, $dstH, $srcW, $srcH);
        imagedestroy($src);
        ob_start();
        imagejpeg($dst, null, 85);
        $imageData = base64_encode(ob_get_clean());
        imagedestroy($dst);
    } else {
        imagedestroy($src);
        $imageData = base64_encode(file_get_contents($photoPath));
    }
} else {
    $imageData = base64_encode(file_get_contents($photoPath));
}

// ── Call Claude API ───────────────────────────────────────────────────────────
$prompt = 'This is a photo from a LiDAR room scanner (portrait orientation). '
        . 'Identify all DOORS and WINDOWS visible. '
        . 'For each, return a bounding box as [x1, y1, x2, y2] in normalized coordinates (0.0-1.0) '
        . 'where [0,0] is top-left and [1,1] is bottom-right of the image. '
        . 'Return ONLY valid JSON in this exact format, nothing else: '
        . '{"doors":[[x1,y1,x2,y2],...],"windows":[[x1,y1,x2,y2],...]} '
        . 'If none found, return {"doors":[],"windows":[]}.';

$payload = json_encode([
    'model'      => 'claude-haiku-4-5-20251001',
    'max_tokens' => 512,
    'messages'   => [[
        'role'    => 'user',
        'content' => [
            ['type' => 'image', 'source' => ['type' => 'base64', 'media_type' => 'image/jpeg', 'data' => $imageData]],
            ['type' => 'text',  'text'   => $prompt],
        ]
    ]]
]);

$ch = curl_init('https://api.anthropic.com/v1/messages');
curl_setopt_array($ch, [
    CURLOPT_POST           => true,
    CURLOPT_POSTFIELDS     => $payload,
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_TIMEOUT        => 30,
    CURLOPT_HTTPHEADER     => [
        'Content-Type: application/json',
        'x-api-key: ' . ANTHROPIC_API_KEY,
        'anthropic-version: 2023-06-01',
    ],
]);
$raw      = curl_exec($ch);
$httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
curl_close($ch);

if ($httpCode !== 200) {
    respond(502, 'Claude API error ' . $httpCode . ': ' . substr($raw, 0, 200));
}

$apiResp = json_decode($raw, true);
$text    = $apiResp['content'][0]['text'] ?? '';

// ── Parse JSON from Claude response ──────────────────────────────────────────
// Claude may wrap the JSON in markdown code fences — strip them
$text = preg_replace('/```(?:json)?\s*([\s\S]*?)```/', '$1', $text);
$text = trim($text);

$detections = json_decode($text, true);
if (json_last_error() !== JSON_ERROR_NONE || !is_array($detections)) {
    respond(502, 'Could not parse Claude response: ' . substr($text, 0, 200));
}

respond(200, null, [
    'success'      => true,
    'session_id'   => $sessionId,
    'photo_index'  => $photoIndex,
    'doors'        => $detections['doors']   ?? [],
    'windows'      => $detections['windows'] ?? [],
]);

function respond(int $code, ?string $error, array $extra = []): never {
    http_response_code($code);
    echo json_encode($error !== null
        ? array_merge(['success' => false, 'error' => $error], $extra)
        : $extra);
    exit;
}
