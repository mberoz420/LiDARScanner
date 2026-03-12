<?php
/**
 * Eva Brain — Central Knowledge Base API
 *
 * GET  /api/eva.php              → returns full knowledge base
 * GET  /api/eva.php?section=X    → returns specific section (params, rules, history, decisions, patterns)
 * POST /api/eva.php              → update knowledge (JSON body with section + data)
 * POST /api/eva.php?action=log   → append to decision/learning log
 * POST /api/eva.php?action=learn → record a learning from corrections
 *
 * Auth: X-API-Key header (same as upload key)
 */

require_once __DIR__ . '/../includes/config.php';

header('Content-Type: application/json');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Headers: Content-Type, X-API-Key');
header('Access-Control-Allow-Methods: GET, POST, OPTIONS');

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') { http_response_code(200); exit; }

// Auth check
$apiKey = $_SERVER['HTTP_X_API_KEY'] ?? '';
if ($apiKey !== UPLOAD_API_KEY) {
    http_response_code(401);
    echo json_encode(['error' => 'Invalid API key']);
    exit;
}

$EVA_DIR = ROOT_PATH . '/eva';
$EVA_FILE = $EVA_DIR . '/knowledge.json';

// Ensure eva directory exists
if (!is_dir($EVA_DIR)) {
    mkdir($EVA_DIR, 0755, true);
}

// Load or initialize knowledge base
function loadKnowledge() {
    global $EVA_FILE;
    if (file_exists($EVA_FILE)) {
        $data = json_decode(file_get_contents($EVA_FILE), true);
        if ($data) return $data;
    }
    // Default knowledge base
    return [
        'version' => 1,
        'updated_at' => date('c'),
        'identity' => [
            'name' => 'Eva',
            'role' => 'AI assistant for LiDAR point cloud analysis, room boundary detection, and surface classification',
            'created' => date('c'),
        ],
        'params' => [
            'cellSize' => 0.03,
            'ridgePercentile' => 0.70,
            'numRays' => 720,
            'ridgeWindow' => 5,
            'simplifyTol' => 0.06,
            'cornerAngle' => 25,
            'snapAngle' => 10,
            'minWallLen' => 0.20,
            'margin' => 1.0,
        ],
        'rules' => [
            [
                'id' => 'wall_detection',
                'rule' => 'Dense, linear point clusters with clear planar density ridges = walls (actual surfaces)',
                'source' => 'user_teaching',
                'created' => date('c'),
            ],
            [
                'id' => 'glass_scatter',
                'rule' => 'Scattered/undefined points inside annotation regions (yellow "Other" polygons) = usually window glass or opening to another room — does NOT define a surface',
                'source' => 'user_teaching',
                'created' => date('c'),
            ],
            [
                'id' => 'noise_classification',
                'rule' => 'Any point cloud area that does not define a plane or logical surface → classify as noise',
                'source' => 'user_teaching',
                'created' => date('c'),
            ],
            [
                'id' => 'blind_spots',
                'rule' => 'LiDAR gaps (missing data) at 75-90° angles from scanner center = blind spots where walls are nearly parallel to the scan ray',
                'source' => 'user_teaching',
                'created' => date('c'),
            ],
            [
                'id' => 'scanner_position',
                'rule' => 'Scanner is typically positioned in the middle of the room',
                'source' => 'user_teaching',
                'created' => date('c'),
            ],
        ],
        'decisions' => [],      // logged decisions with reasoning
        'learnings' => [],      // what Eva learned from corrections
        'patterns' => [],       // recognized scan patterns
        'scan_history' => [],   // summary of scans Eva has worked on
    ];
}

function saveKnowledge($data) {
    global $EVA_FILE;
    $data['updated_at'] = date('c');
    file_put_contents($EVA_FILE, json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE));
}

// ── GET: Read knowledge ──
if ($_SERVER['REQUEST_METHOD'] === 'GET') {
    $kb = loadKnowledge();
    $section = $_GET['section'] ?? null;

    if ($section && isset($kb[$section])) {
        echo json_encode(['section' => $section, 'data' => $kb[$section]]);
    } else {
        echo json_encode($kb);
    }
    exit;
}

// ── POST: Update knowledge ──
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $input = json_decode(file_get_contents('php://input'), true);
    if (!$input) {
        http_response_code(400);
        echo json_encode(['error' => 'Invalid JSON body']);
        exit;
    }

    $kb = loadKnowledge();
    $action = $_GET['action'] ?? $input['action'] ?? 'update';

    switch ($action) {
        case 'update':
            // Update a specific section
            $section = $input['section'] ?? null;
            $data = $input['data'] ?? null;
            if (!$section || $data === null) {
                http_response_code(400);
                echo json_encode(['error' => 'Requires section and data']);
                exit;
            }
            if (!in_array($section, ['params', 'rules', 'patterns', 'identity'])) {
                http_response_code(400);
                echo json_encode(['error' => 'Invalid section: ' . $section]);
                exit;
            }
            $kb[$section] = $data;
            saveKnowledge($kb);
            echo json_encode(['ok' => true, 'section' => $section, 'message' => 'Updated']);
            break;

        case 'log':
            // Append a decision/event to the log
            $entry = [
                'timestamp' => date('c'),
                'type' => $input['type'] ?? 'decision',
                'source' => $input['source'] ?? 'unknown',   // 'labeler', 'swift', 'claude', 'ollama'
                'action' => $input['log_action'] ?? '',
                'context' => $input['context'] ?? '',
                'reasoning' => $input['reasoning'] ?? '',
            ];
            $kb['decisions'][] = $entry;
            // Keep last 100 decisions
            if (count($kb['decisions']) > 100) {
                $kb['decisions'] = array_slice($kb['decisions'], -100);
            }
            saveKnowledge($kb);
            echo json_encode(['ok' => true, 'message' => 'Decision logged', 'total' => count($kb['decisions'])]);
            break;

        case 'learn':
            // Record a learning from corrections
            $learning = [
                'timestamp' => date('c'),
                'source' => $input['source'] ?? 'labeler',
                'scan_id' => $input['scan_id'] ?? null,
                'comparison' => $input['comparison'] ?? null,
                'param_changes' => $input['param_changes'] ?? null,
                'analysis' => $input['analysis'] ?? '',
                'before_params' => $input['before_params'] ?? null,
                'after_params' => $input['after_params'] ?? null,
            ];
            $kb['learnings'][] = $learning;
            // Keep last 50 learnings
            if (count($kb['learnings']) > 50) {
                $kb['learnings'] = array_slice($kb['learnings'], -50);
            }
            // Also update params if provided
            if ($input['after_params']) {
                $kb['params'] = $input['after_params'];
            }
            saveKnowledge($kb);
            echo json_encode(['ok' => true, 'message' => 'Learning recorded', 'total' => count($kb['learnings'])]);
            break;

        case 'add_rule':
            // Add a new classification rule
            $rule = [
                'id' => $input['id'] ?? 'rule_' . time(),
                'rule' => $input['rule'] ?? '',
                'source' => $input['source'] ?? 'user_teaching',
                'created' => date('c'),
            ];
            if (empty($rule['rule'])) {
                http_response_code(400);
                echo json_encode(['error' => 'Rule text required']);
                exit;
            }
            // Replace if same ID exists
            $replaced = false;
            foreach ($kb['rules'] as $i => $r) {
                if ($r['id'] === $rule['id']) {
                    $kb['rules'][$i] = $rule;
                    $replaced = true;
                    break;
                }
            }
            if (!$replaced) $kb['rules'][] = $rule;
            saveKnowledge($kb);
            echo json_encode(['ok' => true, 'message' => $replaced ? 'Rule updated' : 'Rule added']);
            break;

        case 'scan_summary':
            // Record a scan Eva worked on
            $summary = [
                'timestamp' => date('c'),
                'filename' => $input['filename'] ?? '',
                'point_count' => $input['point_count'] ?? 0,
                'actions' => $input['actions'] ?? [],
                'annotations' => $input['annotations'] ?? 0,
                'guide_lines' => $input['guide_lines'] ?? 0,
            ];
            $kb['scan_history'][] = $summary;
            if (count($kb['scan_history']) > 50) {
                $kb['scan_history'] = array_slice($kb['scan_history'], -50);
            }
            saveKnowledge($kb);
            echo json_encode(['ok' => true, 'message' => 'Scan summary recorded']);
            break;

        default:
            http_response_code(400);
            echo json_encode(['error' => 'Unknown action: ' . $action]);
    }
    exit;
}

http_response_code(405);
echo json_encode(['error' => 'Method not allowed']);
