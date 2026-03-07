<?php
session_start();
if (isset($_SESSION['user_id'])) {
    $redirect = $_GET['redirect'] ?? 'index.php';
    // Prevent open redirect — only allow relative paths
    if (preg_match('#^https?://#i', $redirect) || str_starts_with($redirect, '//')) {
        $redirect = 'index.php';
    }
    header('Location: ' . $redirect);
    exit;
}
$redirect = htmlspecialchars($_GET['redirect'] ?? 'index.php');
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ScanWizard — Login</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { min-height: 100vh; display: flex; align-items: center; justify-content: center; background: #0a0a1a; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; color: #fff; }
        .card { background: #111827; border: 1px solid #1f2937; border-radius: 16px; padding: 40px; width: 400px; max-width: 90vw; box-shadow: 0 20px 60px rgba(0,0,0,0.5); }
        .logo { text-align: center; margin-bottom: 30px; }
        .logo h1 { font-size: 24px; font-weight: 800; }
        .logo h1 span:first-child { color: #fff; }
        .logo h1 span:last-child { color: #fbbf24; }
        .logo p { color: #6b7280; font-size: 13px; margin-top: 4px; }
        .tabs { display: flex; margin-bottom: 24px; border-bottom: 1px solid #1f2937; }
        .tab { flex: 1; padding: 10px; text-align: center; cursor: pointer; color: #6b7280; font-size: 14px; font-weight: 600; border-bottom: 2px solid transparent; transition: all 0.2s; }
        .tab.active { color: #00d9ff; border-bottom-color: #00d9ff; }
        .tab:hover { color: #fff; }
        .form { display: none; }
        .form.active { display: block; }
        .field { margin-bottom: 16px; }
        .field label { display: block; font-size: 12px; color: #9ca3af; margin-bottom: 6px; font-weight: 500; }
        .field input { width: 100%; padding: 10px 14px; background: #0a0a1a; border: 1px solid #374151; border-radius: 8px; color: #fff; font-size: 14px; outline: none; transition: border-color 0.2s; }
        .field input:focus { border-color: #00d9ff; }
        .btn { width: 100%; padding: 12px; background: #00d9ff; color: #000; font-size: 14px; font-weight: 700; border: none; border-radius: 8px; cursor: pointer; transition: background 0.2s; margin-top: 8px; }
        .btn:hover { background: #00c4e6; }
        .btn:disabled { opacity: 0.5; cursor: not-allowed; }
        .msg { margin-top: 12px; padding: 10px; border-radius: 8px; font-size: 13px; display: none; }
        .msg.error { display: block; background: rgba(239,68,68,0.1); color: #f87171; border: 1px solid rgba(239,68,68,0.2); }
        .msg.success { display: block; background: rgba(34,197,94,0.1); color: #4ade80; border: 1px solid rgba(34,197,94,0.2); }
    </style>
</head>
<body>
    <div class="card">
        <div class="logo">
            <h1><span>SCAN</span><span>WIZARD</span></h1>
            <p>LiDAR Point Cloud Lab</p>
        </div>

        <div class="tabs">
            <div class="tab active" onclick="showTab('login')">Sign In</div>
            <div class="tab" onclick="showTab('register')">Register</div>
        </div>

        <div class="form active" id="form-login">
            <div class="field">
                <label>Email</label>
                <input type="email" id="login-email" autocomplete="email">
            </div>
            <div class="field">
                <label>Password</label>
                <input type="password" id="login-password" autocomplete="current-password">
            </div>
            <button class="btn" id="login-btn" onclick="doLogin()">Sign In</button>
            <div class="msg" id="login-msg"></div>
        </div>

        <div class="form" id="form-register">
            <div class="field">
                <label>Full Name</label>
                <input type="text" id="reg-name" autocomplete="name">
            </div>
            <div class="field">
                <label>Email</label>
                <input type="email" id="reg-email" autocomplete="email">
            </div>
            <div class="field">
                <label>Password (min 6 characters)</label>
                <input type="password" id="reg-password" autocomplete="new-password">
            </div>
            <button class="btn" id="reg-btn" onclick="doRegister()">Request Access</button>
            <div class="msg" id="reg-msg"></div>
        </div>
    </div>

    <script>
    const redirect = <?= json_encode($redirect) ?>;

    function showTab(tab) {
        document.querySelectorAll('.tab').forEach((t, i) => t.classList.toggle('active', i === (tab === 'login' ? 0 : 1)));
        document.getElementById('form-login').classList.toggle('active', tab === 'login');
        document.getElementById('form-register').classList.toggle('active', tab === 'register');
    }

    function showMsg(id, text, type) {
        const el = document.getElementById(id);
        el.textContent = text;
        el.className = 'msg ' + type;
    }

    async function doLogin() {
        const btn = document.getElementById('login-btn');
        btn.disabled = true;
        try {
            const res = await fetch('api/auth.php', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({
                    action: 'login',
                    email: document.getElementById('login-email').value,
                    password: document.getElementById('login-password').value
                })
            });
            const data = await res.json();
            if (data.success) {
                window.location.href = redirect;
            } else {
                showMsg('login-msg', data.error, 'error');
            }
        } catch (e) {
            showMsg('login-msg', 'Connection error: ' + e.message, 'error');
        }
        btn.disabled = false;
    }

    async function doRegister() {
        const btn = document.getElementById('reg-btn');
        btn.disabled = true;
        try {
            const res = await fetch('api/auth.php', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({
                    action: 'register',
                    full_name: document.getElementById('reg-name').value,
                    email: document.getElementById('reg-email').value,
                    password: document.getElementById('reg-password').value
                })
            });
            const data = await res.json();
            if (data.success) {
                showMsg('reg-msg', data.message, 'success');
            } else {
                showMsg('reg-msg', data.error, 'error');
            }
        } catch (e) {
            showMsg('reg-msg', 'Connection error: ' + e.message, 'error');
        }
        btn.disabled = false;
    }

    // Enter key submits
    document.getElementById('login-password').addEventListener('keydown', e => { if (e.key === 'Enter') doLogin(); });
    document.getElementById('reg-password').addEventListener('keydown', e => { if (e.key === 'Enter') doRegister(); });
    </script>
</body>
</html>
