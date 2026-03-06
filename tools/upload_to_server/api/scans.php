<?php
/**
 * ScanWizard — Scan Management API
 * Handles delete operations (session-protected).
 */
session_start();
require_once '../includes/config.php';

header('Content-Type: application/json');

if (!isset($_SESSION['user_id'])) {
    http_response_code(401);
    echo json_encode(['success' => false, 'error' => 'Not authenticated']);
    exit;
}

$input  = json_decode(file_get_contents('php://input'), true) ?? [];
$action = $input['action'] ?? '';

switch ($action) {
    case 'delete': handleDelete($input); break;
    default: echo json_encode(['success' => false, 'error' => 'Invalid action']);
}

function handleDelete(array $input): void {
    $filename = basename($input['filename'] ?? '');  // basename prevents path traversal

    if (!$filename) {
        echo json_encode(['success' => false, 'error' => 'Invalid filename']);
        exit;
    }

    // Photogrammetry session — stored as a folder under scans/photos/
    if (str_starts_with($filename, 'photos_')) {
        $sessionPath = SCANS_PATH . '/photos/' . $filename;
        if (!is_dir($sessionPath)) {
            echo json_encode(['success' => false, 'error' => 'Session not found']);
            exit;
        }
        deleteDirectory($sessionPath);
    } else {
        // Regular LiDAR scan — single .json file
        if (!str_ends_with($filename, '.json')) {
            echo json_encode(['success' => false, 'error' => 'Invalid filename']);
            exit;
        }
        $filepath = SCANS_PATH . '/' . $filename;
        if (!file_exists($filepath)) {
            echo json_encode(['success' => false, 'error' => 'File not found']);
            exit;
        }
        if (!unlink($filepath)) {
            echo json_encode(['success' => false, 'error' => 'Could not delete file']);
            exit;
        }
    }

    // Remove from manifest
    $manifestPath = SCANS_PATH . '/manifest.json';
    if (file_exists($manifestPath)) {
        $manifest = json_decode(file_get_contents($manifestPath), true) ?? [];
        $manifest = array_values(array_filter($manifest, fn($s) => $s['filename'] !== $filename));
        file_put_contents($manifestPath, json_encode($manifest, JSON_PRETTY_PRINT));
    }

    echo json_encode(['success' => true]);
}

function deleteDirectory(string $path): void {
    foreach (scandir($path) as $item) {
        if ($item === '.' || $item === '..') continue;
        $full = $path . '/' . $item;
        is_dir($full) ? deleteDirectory($full) : unlink($full);
    }
    rmdir($path);
}
