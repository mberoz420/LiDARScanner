<?php
/**
 * ScanWizard — Codemagic Build Status Proxy
 *
 * Fetches the latest build from the Codemagic API and returns a
 * simplified JSON that PointCloudLabeler.html can display.
 *
 * Keeps the auth token server-side so it's never exposed to the browser.
 */
header('Content-Type: application/json');
header('Access-Control-Allow-Origin: *');
header('Cache-Control: no-cache, no-store');

define('CM_TOKEN', 's2OL8ah62LMTHogrNIIukqEJOewdhZ4tZfy4TPCb1Ko');
define('CM_APP_ID', '69a0ccc39374c00bf5f24cb8');

$url = 'https://api.codemagic.io/builds?appId=' . CM_APP_ID . '&limit=1';

$ctx = stream_context_create([
    'http' => [
        'method'  => 'GET',
        'header'  => 'x-auth-token: ' . CM_TOKEN . "\r\nAccept: application/json\r\n",
        'timeout' => 10,
        'ignore_errors' => true,
    ],
    'ssl' => ['verify_peer' => true],
]);

$raw = @file_get_contents($url, false, $ctx);
if ($raw === false) {
    http_response_code(503);
    echo json_encode(['error' => 'Cannot reach Codemagic API']);
    exit;
}

$data = json_decode($raw, true);
$build = $data['builds'][0] ?? null;

if (!$build) {
    http_response_code(404);
    echo json_encode(['error' => 'No builds found']);
    exit;
}

// Map Codemagic status → display status
$cm_status = $build['status'] ?? '';
if ($cm_status === 'finished') {
    $status = 'success';
} elseif (in_array($cm_status, ['failed', 'timeout', 'canceled'])) {
    $status = 'failed';
} else {
    $status = 'building'; // queued / preparing / building / finishing
}

echo json_encode([
    'status'       => $status,
    'cm_status'    => $cm_status,
    'build_number' => $build['buildNumber'] ?? '?',
    'branch'       => $build['branch'] ?? null,
    'version'      => $build['version'] ?? null,
    'commit'       => $build['commit']['commitSha'] ?? null,
    'timestamp'    => $build['finishedAt'] ?? $build['startedAt'] ?? null,
    'errors'       => [],
]);
