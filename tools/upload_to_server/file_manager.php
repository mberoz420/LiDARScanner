<?php
/**
 * ScanWizard — File Manager API
 * Browse, delete, copy, create folders/files in the scans directory.
 * Authenticated by X-API-Key header.
 *
 * GET  ?action=list&path=         — list directory contents
 * POST action=delete   path=...   — delete file or empty folder
 * POST action=mkdir    path=...   — create folder
 * POST action=copy     from=... to=...  — copy file
 * POST action=rename   path=... name=...  — rename file/folder
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

// Sanitize a relative path — prevent directory traversal
function safePath(string $rel): string {
    $rel = str_replace('\\', '/', $rel);
    $rel = preg_replace('#\.\./#', '', $rel);          // strip ../
    $rel = preg_replace('#/\.\.#', '', $rel);          // strip /..
    $rel = preg_replace('#^\.\.#', '', $rel);          // strip leading ..
    $rel = preg_replace('#[^a-zA-Z0-9_\-./\s]#', '', $rel);
    $rel = trim($rel, '/');
    return $rel;
}

function fullPath(string $rel): string {
    return SCANS_PATH . ($rel !== '' ? '/' . $rel : '');
}

$action = $_GET['action'] ?? '';

if ($_SERVER['REQUEST_METHOD'] === 'GET' && $action === 'list') {
    $rel  = safePath($_GET['path'] ?? '');
    $dir  = fullPath($rel);

    if (!is_dir($dir)) {
        http_response_code(404);
        echo json_encode(['error' => 'Directory not found']);
        exit;
    }

    $items = [];
    foreach (scandir($dir) as $entry) {
        if ($entry === '.' || $entry === '..') continue;
        $entryPath = $dir . '/' . $entry;
        $isDir = is_dir($entryPath);
        $item = [
            'name'    => $entry,
            'type'    => $isDir ? 'folder' : 'file',
            'size'    => $isDir ? 0 : filesize($entryPath),
            'modified' => date('c', filemtime($entryPath)),
        ];
        if (!$isDir && str_ends_with($entry, '.json') && $entry !== 'manifest.json') {
            // Try to get point count from JSON
            $data = json_decode(file_get_contents($entryPath), true);
            if ($data) {
                $item['num_points'] = (int)($data['num_points'] ?? count($data['points'] ?? []));
            }
        }
        $items[] = $item;
    }

    // Sort: folders first, then files, alphabetical
    usort($items, function($a, $b) {
        if ($a['type'] !== $b['type']) return $a['type'] === 'folder' ? -1 : 1;
        return strcasecmp($a['name'], $b['name']);
    });

    echo json_encode(['path' => $rel, 'items' => $items]);
    exit;
}

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $input  = json_decode(file_get_contents('php://input'), true) ?? [];
    $action = $input['action'] ?? '';

    switch ($action) {
        case 'mkdir': {
            $rel  = safePath($input['path'] ?? '');
            $dir  = fullPath($rel);
            if (is_dir($dir)) {
                echo json_encode(['success' => true, 'message' => 'Already exists']);
            } elseif (mkdir($dir, 0755, true)) {
                echo json_encode(['success' => true]);
            } else {
                echo json_encode(['success' => false, 'error' => 'Failed to create folder']);
            }
            break;
        }

        case 'delete': {
            $rel  = safePath($input['path'] ?? '');
            if ($rel === '') {
                echo json_encode(['success' => false, 'error' => 'Cannot delete root']);
                break;
            }
            $path = fullPath($rel);
            if (is_dir($path)) {
                // Only delete if empty or force recursive
                $empty = count(array_diff(scandir($path), ['.', '..'])) === 0;
                if ($empty) {
                    rmdir($path);
                    echo json_encode(['success' => true]);
                } else {
                    // Recursive delete
                    deleteRecursive($path);
                    echo json_encode(['success' => true]);
                }
            } elseif (is_file($path)) {
                unlink($path);
                echo json_encode(['success' => true]);
            } else {
                echo json_encode(['success' => false, 'error' => 'Not found']);
            }
            break;
        }

        case 'copy': {
            $from = safePath($input['from'] ?? '');
            $to   = safePath($input['to'] ?? '');
            if ($from === '' || $to === '') {
                echo json_encode(['success' => false, 'error' => 'Invalid paths']);
                break;
            }
            $srcPath = fullPath($from);
            $dstPath = fullPath($to);
            if (!is_file($srcPath)) {
                echo json_encode(['success' => false, 'error' => 'Source not found']);
                break;
            }
            // Ensure destination directory exists
            $dstDir = dirname($dstPath);
            if (!is_dir($dstDir)) mkdir($dstDir, 0755, true);
            if (copy($srcPath, $dstPath)) {
                echo json_encode(['success' => true]);
            } else {
                echo json_encode(['success' => false, 'error' => 'Copy failed']);
            }
            break;
        }

        case 'rename': {
            $rel  = safePath($input['path'] ?? '');
            $name = preg_replace('/[^a-zA-Z0-9_\-. ]/', '', $input['name'] ?? '');
            $name = trim($name);
            if ($rel === '' || $name === '') {
                echo json_encode(['success' => false, 'error' => 'Invalid path or name']);
                break;
            }
            $oldPath = fullPath($rel);
            $parent  = dirname($oldPath);
            $newPath = $parent . '/' . $name;
            if (!file_exists($oldPath)) {
                echo json_encode(['success' => false, 'error' => 'Not found']);
            } elseif (file_exists($newPath)) {
                echo json_encode(['success' => false, 'error' => 'Name already exists']);
            } elseif (rename($oldPath, $newPath)) {
                echo json_encode(['success' => true]);
            } else {
                echo json_encode(['success' => false, 'error' => 'Rename failed']);
            }
            break;
        }

        case 'move': {
            $from = safePath($input['from'] ?? '');
            $to   = safePath($input['to'] ?? '');
            if ($from === '' || $to === '') {
                echo json_encode(['success' => false, 'error' => 'Invalid paths']);
                break;
            }
            $srcPath = fullPath($from);
            $dstPath = fullPath($to);
            if (!file_exists($srcPath)) {
                echo json_encode(['success' => false, 'error' => 'Source not found']);
                break;
            }
            $dstDir = dirname($dstPath);
            if (!is_dir($dstDir)) mkdir($dstDir, 0755, true);
            if (rename($srcPath, $dstPath)) {
                echo json_encode(['success' => true]);
            } else {
                echo json_encode(['success' => false, 'error' => 'Move failed']);
            }
            break;
        }

        default:
            echo json_encode(['success' => false, 'error' => 'Unknown action: ' . $action]);
    }
    exit;
}

http_response_code(405);
echo json_encode(['error' => 'Method not allowed']);

function deleteRecursive(string $dir): void {
    foreach (scandir($dir) as $entry) {
        if ($entry === '.' || $entry === '..') continue;
        $path = $dir . '/' . $entry;
        if (is_dir($path)) {
            deleteRecursive($path);
        } else {
            unlink($path);
        }
    }
    rmdir($dir);
}
