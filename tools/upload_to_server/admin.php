<?php
session_start();
require_once 'includes/db.php';

if (!isset($_SESSION['user']) || !$_SESSION['user']['is_admin']) {
    header('Location: login.php');
    exit;
}
$user = $_SESSION['user'];
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ScanWizard — Admin</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { min-height: 100vh; background: #0a0a1a; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; color: #fff; }
        .topbar { display: flex; align-items: center; justify-content: space-between; padding: 16px 24px; background: #111827; border-bottom: 1px solid #1f2937; }
        .topbar h1 { font-size: 18px; font-weight: 800; }
        .topbar h1 span:first-child { color: #fff; }
        .topbar h1 span:last-child { color: #fbbf24; }
        .topbar .links { display: flex; gap: 16px; align-items: center; }
        .topbar a { color: #9ca3af; text-decoration: none; font-size: 13px; }
        .topbar a:hover { color: #fff; }
        .container { max-width: 900px; margin: 30px auto; padding: 0 20px; }
        .section-title { font-size: 14px; color: #6b7280; text-transform: uppercase; letter-spacing: 1px; margin-bottom: 16px; font-weight: 600; }
        .tabs { display: flex; gap: 8px; margin-bottom: 20px; }
        .tab-btn { padding: 8px 16px; border-radius: 8px; border: 1px solid #1f2937; background: transparent; color: #9ca3af; font-size: 13px; cursor: pointer; font-weight: 600; }
        .tab-btn.active { background: #1f2937; color: #00d9ff; border-color: #00d9ff; }
        .tab-btn:hover { color: #fff; }
        .badge { display: inline-block; background: #fbbf24; color: #000; font-size: 11px; font-weight: 700; padding: 2px 7px; border-radius: 10px; margin-left: 6px; }
        table { width: 100%; border-collapse: collapse; }
        th { text-align: left; font-size: 11px; color: #6b7280; text-transform: uppercase; letter-spacing: 0.5px; padding: 10px 12px; border-bottom: 1px solid #1f2937; }
        td { padding: 12px; border-bottom: 1px solid #1f2937; font-size: 14px; }
        tr:hover td { background: rgba(255,255,255,0.02); }
        .status { display: inline-block; padding: 3px 10px; border-radius: 6px; font-size: 12px; font-weight: 600; }
        .status.pending { background: rgba(251,191,36,0.15); color: #fbbf24; }
        .status.approved { background: rgba(34,197,94,0.15); color: #4ade80; }
        .status.rejected { background: rgba(239,68,68,0.15); color: #f87171; }
        .action-btn { padding: 5px 12px; border-radius: 6px; border: none; font-size: 12px; font-weight: 600; cursor: pointer; margin-right: 4px; }
        .action-btn.approve { background: #22c55e; color: #000; }
        .action-btn.approve:hover { background: #16a34a; }
        .action-btn.reject { background: #ef4444; color: #fff; }
        .action-btn.reject:hover { background: #dc2626; }
        .action-btn:disabled { opacity: 0.4; cursor: not-allowed; }
        .empty { text-align: center; padding: 40px; color: #6b7280; font-size: 14px; }
        .date { color: #6b7280; font-size: 12px; }
    </style>
</head>
<body>
    <div class="topbar">
        <h1><span>SCAN</span><span>WIZARD</span> <span style="color:#6b7280;font-size:13px;font-weight:400;">Admin</span></h1>
        <div class="links">
            <a href="index.php">Dashboard</a>
            <a href="#" onclick="doLogout()">Sign Out</a>
        </div>
    </div>

    <div class="container">
        <div class="section-title">User Management</div>

        <div class="tabs">
            <button class="tab-btn active" data-status="pending">Pending <span id="badge-pending" class="badge" style="display:none"></span></button>
            <button class="tab-btn" data-status="approved">Approved</button>
            <button class="tab-btn" data-status="rejected">Rejected</button>
            <button class="tab-btn" data-status="all">All</button>
        </div>

        <table>
            <thead>
                <tr>
                    <th>Name</th>
                    <th>Email</th>
                    <th>Status</th>
                    <th>Registered</th>
                    <th>Actions</th>
                </tr>
            </thead>
            <tbody id="user-tbody">
                <tr><td colspan="5" class="empty">Loading...</td></tr>
            </tbody>
        </table>
    </div>

    <script>
    let allUsers = [];
    let currentFilter = 'pending';

    document.querySelectorAll('.tab-btn').forEach(btn => {
        btn.addEventListener('click', () => {
            document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
            btn.classList.add('active');
            currentFilter = btn.dataset.status;
            renderUsers();
        });
    });

    async function loadUsers() {
        try {
            const res = await fetch('api/auth.php', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({ action: 'list_users' })
            });
            const data = await res.json();
            if (data.success) {
                allUsers = data.users;
                const pendingCount = allUsers.filter(u => u.status === 'pending').length;
                const badge = document.getElementById('badge-pending');
                if (pendingCount > 0) {
                    badge.textContent = pendingCount;
                    badge.style.display = 'inline-block';
                } else {
                    badge.style.display = 'none';
                }
                renderUsers();
            }
        } catch (e) {
            document.getElementById('user-tbody').innerHTML = '<tr><td colspan="5" class="empty">Failed to load users</td></tr>';
        }
    }

    function renderUsers() {
        const filtered = currentFilter === 'all' ? allUsers : allUsers.filter(u => u.status === currentFilter);
        const tbody = document.getElementById('user-tbody');

        if (filtered.length === 0) {
            tbody.innerHTML = '<tr><td colspan="5" class="empty">No users found</td></tr>';
            return;
        }

        tbody.innerHTML = filtered.map(u => `
            <tr>
                <td>${esc(u.full_name)}${u.is_admin == 1 ? ' <span style="color:#fbbf24;font-size:11px;">ADMIN</span>' : ''}</td>
                <td>${esc(u.email)}</td>
                <td><span class="status ${u.status}">${u.status}</span></td>
                <td class="date">${u.created_at || '—'}</td>
                <td>
                    ${u.status === 'pending' ? `
                        <button class="action-btn approve" onclick="doAction('approve', ${u.id}, this)">Approve</button>
                        <button class="action-btn reject" onclick="doAction('reject', ${u.id}, this)">Reject</button>
                    ` : u.status === 'rejected' ? `
                        <button class="action-btn approve" onclick="doAction('approve', ${u.id}, this)">Approve</button>
                    ` : u.status === 'approved' && u.is_admin != 1 ? `
                        <button class="action-btn reject" onclick="doAction('reject', ${u.id}, this)">Revoke</button>
                    ` : ''}
                </td>
            </tr>
        `).join('');
    }

    async function doAction(action, userId, btn) {
        btn.disabled = true;
        try {
            const res = await fetch('api/auth.php', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({ action, user_id: userId })
            });
            const data = await res.json();
            if (data.success) {
                loadUsers();
            } else {
                alert(data.error || 'Action failed');
                btn.disabled = false;
            }
        } catch (e) {
            alert('Connection error');
            btn.disabled = false;
        }
    }

    async function doLogout() {
        await fetch('api/auth.php', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({ action: 'logout' })
        });
        window.location.href = 'login.php';
    }

    function esc(s) {
        const d = document.createElement('div');
        d.textContent = s;
        return d.innerHTML;
    }

    loadUsers();
    </script>
</body>
</html>
