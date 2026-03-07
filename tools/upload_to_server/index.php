<?php
/**
 * ScanWizard — Scan Dashboard
 * Matches Robo-Wizard's visual style (hero header, stats bar, card grid).
 */
session_start();
require_once 'includes/config.php';

if (!isset($_SESSION['user_id'])) {
    header('Location: login.php?redirect=' . urlencode($_SERVER['REQUEST_URI']));
    exit;
}

$user = $_SESSION['user'];

// ── Load manifest ────────────────────────────────────────────────────────────
$manifestPath = SCANS_PATH . '/manifest.json';
$scans = file_exists($manifestPath)
    ? (json_decode(file_get_contents($manifestPath), true) ?? [])
    : [];

// Stats
$total      = count($scans);
$thisWeek   = array_filter($scans, fn($s) => ($s['timestamp'] ?? 0) >= strtotime('-7 days'));
$latestDate = $total > 0 ? date('M j', $scans[0]['timestamp'] ?? time()) : '—';
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ScanWizard — Scans</title>
    <link rel="stylesheet" href="assets/css/style.css">
</head>
<body>

<!-- ── Hero Header (matches Robo-Wizard hero-section) ────────────────────── -->
<header class="hero-section">
    <div class="hero-logo">
        <svg viewBox="0 0 280 60" xmlns="http://www.w3.org/2000/svg" width="220">
            <text x="8" y="44" font-family="Arial Black,sans-serif" font-size="30" font-weight="900" fill="white">SCAN</text>
            <circle cx="112" cy="30" r="9" fill="white" opacity="0.3"/>
            <circle cx="112" cy="30" r="5" fill="#4ade80"/>
            <text x="128" y="44" font-family="Arial,sans-serif" font-size="25" font-weight="700" fill="#fbbf24">WIZARD</text>
            <text x="252" y="16" font-size="12" fill="#fbbf24">✦</text>
            <text x="266" y="30" font-size="9"  fill="#fbbf24">✦</text>
        </svg>
    </div>

    <div class="hero-center">
        <span class="hero-tagline">
            Your private <span class="highlight">LiDAR scan lab</span>
        </span>
    </div>

    <div class="hero-right">
        <div class="user-menu">
            <button class="user-btn" onclick="toggleUserMenu()">
                <span class="user-avatar"><?= strtoupper(substr($user['full_name'] ?? 'U', 0, 1)) ?></span>
                <span class="user-name"><?= htmlspecialchars($user['full_name'] ?? '') ?></span>
                <svg width="16" height="16" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7"/>
                </svg>
            </button>
            <div class="user-dropdown" id="userDropdown">
                <div class="dropdown-email"><?= htmlspecialchars($user['email'] ?? '') ?></div>
                <?php if (!empty($user['is_admin'])): ?>
                <a href="admin.php" class="dropdown-item">
                    <svg width="16" height="16" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4.354a4 4 0 110 5.292M15 21H3v-1a6 6 0 0112 0v1zm0 0h6v-1a6 6 0 00-9-5.197"/>
                    </svg>
                    Admin Panel
                </a>
                <?php endif; ?>
                <a href="#" onclick="logout()" class="dropdown-item danger">
                    <svg width="16" height="16" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 16l4-4m0 0l-4-4m4 4H7m6 4v1a3 3 0 01-3 3H6a3 3 0 01-3-3V7a3 3 0 013-3h4a3 3 0 013 3v1"/>
                    </svg>
                    Sign Out
                </a>
            </div>
        </div>
    </div>
</header>

<div class="container">

    <!-- ── Stats Bar ──────────────────────────────────────────────────────── -->
    <div class="stats-bar">
        <div class="stat">
            <span class="stat-value"><?= $total ?></span>
            <span class="stat-label">Total Scans</span>
        </div>
        <div class="stat">
            <span class="stat-value"><?= count($thisWeek) ?></span>
            <span class="stat-label">This Week</span>
        </div>
        <div class="stat">
            <span class="stat-value"><?= $latestDate ?></span>
            <span class="stat-label">Latest</span>
        </div>
    </div>

    <!-- ── Scan Grid ──────────────────────────────────────────────────────── -->
    <div class="section-header">
        <h2>Your Scans</h2>
        <span class="section-sub">Click a scan to open it in the labeler</span>
    </div>

    <?php if (!empty($scans)): ?>
    <div style="display:flex;gap:10px;margin-bottom:14px;align-items:center">
        <button onclick="toggleSelectAll()" id="btn-select-all"
                style="padding:6px 14px;background:#2a2a3a;border:1px solid #444;color:#ccc;border-radius:8px;cursor:pointer;font-size:13px">
            ☑ Select All
        </button>
        <button onclick="deleteSelected()" id="btn-delete-selected"
                style="padding:6px 14px;background:#7f1d1d;border:1px solid #ef4444;color:#fca5a5;border-radius:8px;cursor:pointer;font-size:13px;display:none">
            🗑 Delete Selected (<span id="selected-count">0</span>)
        </button>
    </div>
    <?php endif; ?>

    <?php if (empty($scans)): ?>
    <div class="empty-state">
        <div class="empty-icon">📡</div>
        <h3>No scans yet</h3>
        <p>Scans uploaded from your iPhone will appear here automatically.</p>
    </div>
    <?php else: ?>
    <div class="scan-grid">
        <?php foreach ($scans as $scan):
            $filename  = htmlspecialchars($scan['filename'] ?? '');
            $ts        = $scan['timestamp'] ?? 0;
            $points    = number_format($scan['num_points'] ?? 0);
            $date      = date('M j, Y', $ts);
            $time      = date('g:i a', $ts);
            $scanNum   = basename($filename, '.json');
            $age       = $ts > 0 ? human_time($ts) : '';
        ?>
        <div class="scan-card" data-filename="<?= $filename ?>" style="position:relative">
            <label style="position:absolute;top:8px;left:8px;display:none" class="scan-checkbox-wrap">
                <input type="checkbox" class="scan-checkbox" value="<?= $filename ?>" onchange="updateSelection()">
            </label>
            <div class="scan-card-header">
                <div class="scan-icon">
                    <svg width="28" height="28" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"
                              d="M3 7h18M3 12h18M3 17h18M7 3v18M17 3v18"/>
                    </svg>
                </div>
                <div class="scan-meta">
                    <span class="scan-date"><?= $date ?></span>
                    <span class="scan-time"><?= $time ?></span>
                </div>
                <?php if ($age): ?>
                <span class="scan-age"><?= $age ?></span>
                <?php endif; ?>
            </div>

            <div class="scan-filename"><?= $filename ?></div>

            <?php if ($points !== '0'): ?>
            <div class="scan-points">
                <svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <circle cx="12" cy="12" r="3" stroke-width="2"/>
                    <path stroke-linecap="round" stroke-width="2" d="M3 12h2m14 0h2M12 3v2m0 14v2"/>
                </svg>
                <?= $points ?> points
            </div>
            <?php endif; ?>

            <div class="scan-actions">
                <a href="labeler.php?v=2.0&scan=<?= $filename ?>" class="btn-view">
                    Open in Labeler
                    <svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14"/>
                    </svg>
                </a>
                <button class="btn-delete" onclick="deleteScan('<?= $filename ?>', this)" title="Delete scan">
                    <svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"/>
                    </svg>
                </button>
            </div>
        </div>
        <?php endforeach; ?>
    </div>
    <?php endif; ?>

</div>

<!-- ── Footer ──────────────────────────────────────────────────────────────── -->
<footer>
    <p>ScanWizard &mdash; part of the <a href="https://robo-wizard.com">Robo-Wizard</a> ecosystem</p>
</footer>

<script>
let selectMode = false;

function toggleSelectAll() {
    selectMode = !selectMode;
    document.querySelectorAll('.scan-checkbox-wrap').forEach(el => {
        el.style.display = selectMode ? '' : 'none';
    });
    document.querySelectorAll('.scan-checkbox').forEach(cb => {
        cb.checked = selectMode;
    });
    document.getElementById('btn-select-all').textContent = selectMode ? '✕ Cancel' : '☑ Select All';
    updateSelection();
}

function updateSelection() {
    const checked = document.querySelectorAll('.scan-checkbox:checked');
    const btn = document.getElementById('btn-delete-selected');
    document.getElementById('selected-count').textContent = checked.length;
    btn.style.display = checked.length > 0 ? '' : 'none';
}

async function deleteSelected() {
    const checked = [...document.querySelectorAll('.scan-checkbox:checked')];
    if (!checked.length) return;
    if (!confirm(`Delete ${checked.length} scan(s)? This cannot be undone.`)) return;

    const btn = document.getElementById('btn-delete-selected');
    btn.disabled = true;

    for (const cb of checked) {
        const filename = cb.value;
        try {
            const r = await fetch('api/scans.php', {
                method: 'POST',
                headers: {'Content-Type':'application/json'},
                body: JSON.stringify({action:'delete', filename})
            });
            const d = await r.json();
            if (d.success) cb.closest('.scan-card').remove();
            else alert('Delete failed for ' + filename + ': ' + (d.error || 'Unknown error'));
        } catch (e) { alert('Connection error deleting ' + filename + ': ' + e.message); }
    }

    btn.disabled = false;
    updateSelection();
    if (!document.querySelectorAll('.scan-card').length) {
        document.querySelector('.scan-grid')?.remove();
    }
}

function toggleUserMenu() {
    document.getElementById('userDropdown').classList.toggle('open');
}
document.addEventListener('click', e => {
    if (!e.target.closest('.user-menu')) {
        document.getElementById('userDropdown').classList.remove('open');
    }
});

async function logout() {
    await fetch('api/auth.php', {
        method: 'POST',
        headers: {'Content-Type':'application/json'},
        body: JSON.stringify({action:'logout'})
    });
    window.location.href = 'login.php';
}

async function deleteScan(filename, btn) {
    if (!confirm('Delete this scan? This cannot be undone.')) return;
    btn.disabled = true;
    try {
        const r = await fetch('api/scans.php', {
            method: 'POST',
            headers: {'Content-Type':'application/json'},
            body: JSON.stringify({action:'delete', filename})
        });
        const d = await r.json();
        if (d.success) btn.closest('.scan-card').remove();
        else alert('Delete failed: ' + (d.error || 'Unknown error'));
    } catch { alert('Connection error.'); }
    btn.disabled = false;
}
</script>
</body>
</html>
<?php
function human_time(int $ts): string {
    $diff = time() - $ts;
    if ($diff < 60)    return 'just now';
    if ($diff < 3600)  return round($diff/60) . 'm ago';
    if ($diff < 86400) return round($diff/3600) . 'h ago';
    if ($diff < 604800)return round($diff/86400) . 'd ago';
    return '';
}
?>
