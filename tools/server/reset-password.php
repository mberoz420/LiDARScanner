<?php
/**
 * ScanWizard — Reset Password
 * Landing page from email reset link. Verifies token, accepts new password.
 */
session_start();
$token = $_GET['token'] ?? '';
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Reset Password — ScanWizard</title>
    <style>
        :root {
            --primary:      #3b82f6;
            --primary-dark: #1d4ed8;
            --secondary:    #64748b;
            --dark:         #0f172a;
            --light:        #f1f5f9;
            --border:       #e2e8f0;
            --success:      #10b981;
            --error:        #ef4444;
        }
        * { margin: 0; padding: 0; box-sizing: border-box; }

        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #0f172a 0%, #1e293b 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            padding: 1rem;
        }

        .login-container {
            background: white;
            border-radius: 16px;
            box-shadow: 0 25px 50px -12px rgba(0,0,0,0.5);
            width: 100%;
            max-width: 420px;
            overflow: hidden;
        }

        .login-header {
            background: linear-gradient(135deg, var(--primary), var(--primary-dark));
            padding: 2rem;
            text-align: center;
            color: white;
        }
        .login-header p { opacity: 0.9; font-size: 0.95rem; margin-top: 0.5rem; }

        .logo { margin-bottom: 0.25rem; }
        .logo svg { width: 200px; height: auto; }

        .form-container { padding: 2rem; }

        .form-group { margin-bottom: 1.25rem; }
        .form-group label {
            display: block; font-weight: 600; color: var(--dark);
            margin-bottom: 0.5rem; font-size: 0.9rem;
        }
        .form-group input {
            width: 100%; padding: 0.875rem 1rem;
            border: 2px solid var(--border); border-radius: 8px;
            font-size: 1rem; transition: border-color 0.2s;
        }
        .form-group input:focus { outline: none; border-color: var(--primary); }
        .form-group small { display: block; color: var(--secondary); font-size: 0.8rem; margin-top: 0.35rem; }

        .password-wrapper { position: relative; display: flex; }
        .password-wrapper input { padding-right: 45px; }
        .password-toggle {
            position: absolute; right: 8px; top: 50%; transform: translateY(-50%);
            background: none; border: none; cursor: pointer; padding: 6px;
            color: var(--secondary); display: flex; align-items: center; justify-content: center;
            border-radius: 4px; transition: color 0.2s, background 0.2s;
        }
        .password-toggle:hover { color: var(--primary); background: var(--light); }
        .password-toggle svg { width: 20px; height: 20px; }

        .btn {
            width: 100%; padding: 1rem; border: none; border-radius: 8px;
            font-size: 1rem; font-weight: 600; cursor: pointer; transition: all 0.2s;
        }
        .btn-primary {
            background: linear-gradient(135deg, var(--primary), var(--primary-dark));
            color: white;
        }
        .btn-primary:hover { transform: translateY(-2px); box-shadow: 0 4px 12px rgba(59,130,246,0.4); }
        .btn-primary:disabled { opacity: 0.7; cursor: not-allowed; transform: none; }

        .message {
            padding: 0.875rem 1rem; border-radius: 8px;
            margin-bottom: 1rem; font-size: 0.9rem; display: none;
        }
        .message.error  { background: #fef2f2; color: var(--error);   border: 1px solid #fecaca; display: block; }
        .message.success { background: #ecfdf5; color: var(--success); border: 1px solid #a7f3d0; display: block; }

        .back-link {
            text-align: center; margin-top: 1.5rem;
            padding-top: 1.5rem; border-top: 1px solid var(--border);
        }
        .back-link a { color: var(--secondary); text-decoration: none; font-size: 0.9rem; }
        .back-link a:hover { color: var(--primary); }

        @media (max-width: 480px) {
            .login-header { padding: 1.5rem; }
            .form-container { padding: 1.5rem; }
        }
    </style>
</head>
<body>
<div class="login-container">
    <div class="login-header">
        <div class="logo">
            <svg viewBox="0 0 340 70" xmlns="http://www.w3.org/2000/svg">
                <text x="10" y="50" font-family="Arial Black,sans-serif" font-size="34" font-weight="900" fill="white">SCAN</text>
                <circle cx="130" cy="35" r="10" fill="white" opacity="0.3"/>
                <circle cx="130" cy="35" r="6" fill="#4ade80"/>
                <text x="150" y="50" font-family="Arial,sans-serif" font-size="28" font-weight="700" fill="#fbbf24">WIZARD</text>
                <text x="300" y="20" font-size="14" fill="#fbbf24">&#10022;</text>
                <text x="318" y="38" font-size="10" fill="#fbbf24">&#10022;</text>
            </svg>
        </div>
        <p>Reset your password</p>
    </div>

    <div class="form-container">
        <div id="message" class="message"></div>

        <!-- Loading state -->
        <div id="loadingState" style="text-align:center; padding:2rem 0; color:var(--secondary);">
            Verifying reset link...
        </div>

        <!-- Invalid token -->
        <div id="invalidState" style="display:none; text-align:center; padding:1rem 0;">
            <p style="color:var(--error); font-weight:600; margin-bottom:1rem;">This reset link is invalid or has expired.</p>
            <p style="color:var(--secondary); font-size:0.9rem;">Please request a new password reset from the login page.</p>
        </div>

        <!-- Reset form -->
        <form id="resetForm" style="display:none;" onsubmit="handleReset(event)">
            <div class="form-group">
                <label for="newPassword">New Password</label>
                <div class="password-wrapper">
                    <input type="password" id="newPassword" required minlength="6" autocomplete="new-password">
                    <button type="button" class="password-toggle" onclick="togglePassword('newPassword',this)" aria-label="Show password">
                        <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"/>
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"/>
                        </svg>
                    </button>
                </div>
                <small>Minimum 6 characters</small>
            </div>
            <div class="form-group">
                <label for="confirmPassword">Confirm Password</label>
                <div class="password-wrapper">
                    <input type="password" id="confirmPassword" required minlength="6" autocomplete="new-password">
                    <button type="button" class="password-toggle" onclick="togglePassword('confirmPassword',this)" aria-label="Show password">
                        <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"/>
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"/>
                        </svg>
                    </button>
                </div>
            </div>
            <button type="submit" class="btn btn-primary" id="resetBtn">Reset Password</button>
        </form>

        <!-- Success state -->
        <div id="successState" style="display:none; text-align:center; padding:1rem 0;">
            <p style="color:var(--success); font-weight:600; font-size:1.1rem; margin-bottom:0.5rem;">Password reset successful!</p>
            <p style="color:var(--secondary); font-size:0.9rem;">Redirecting to login...</p>
        </div>

        <div class="back-link">
            <a href="login.php">&larr; Back to Login</a>
        </div>
    </div>
</div>

<script>
const token = <?= json_encode($token) ?>;

function togglePassword(id, btn) {
    const input = document.getElementById(id);
    const isHidden = input.type === 'password';
    input.type = isHidden ? 'text' : 'password';
    btn.innerHTML = isHidden
        ? '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13.875 18.825A10.05 10.05 0 0112 19c-4.478 0-8.268-2.943-9.543-7a9.97 9.97 0 011.563-3.029m5.858.908a3 3 0 114.243 4.243M9.878 9.878l4.242 4.242M9.88 9.88l-3.29-3.29m7.532 7.532l3.29 3.29M3 3l3.59 3.59m0 0A9.953 9.953 0 0112 5c4.478 0 8.268 2.943 9.543 7a10.025 10.025 0 01-4.132 5.411m0 0L21 21"/></svg>'
        : '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"/><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"/></svg>';
    btn.setAttribute('aria-label', isHidden ? 'Hide password' : 'Show password');
}

function showMsg(text, type) {
    const m = document.getElementById('message');
    m.textContent = text;
    m.className = 'message ' + type;
}
function hideMsg() { document.getElementById('message').className = 'message'; }

async function post(action, data) {
    const r = await fetch('api/auth.php', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action, ...data })
    });
    return r.json();
}

// Verify token on page load
async function verifyToken() {
    if (!token) {
        document.getElementById('loadingState').style.display = 'none';
        document.getElementById('invalidState').style.display = 'block';
        return;
    }
    try {
        const d = await post('verify_reset_token', { token });
        document.getElementById('loadingState').style.display = 'none';
        if (d.success) {
            document.getElementById('resetForm').style.display = 'block';
        } else {
            document.getElementById('invalidState').style.display = 'block';
        }
    } catch {
        document.getElementById('loadingState').style.display = 'none';
        document.getElementById('invalidState').style.display = 'block';
    }
}

async function handleReset(e) {
    e.preventDefault();
    hideMsg();

    const password = document.getElementById('newPassword').value;
    const confirm = document.getElementById('confirmPassword').value;

    if (password !== confirm) {
        showMsg('Passwords do not match.', 'error');
        return;
    }
    if (password.length < 6) {
        showMsg('Password must be at least 6 characters.', 'error');
        return;
    }

    const btn = document.getElementById('resetBtn');
    btn.disabled = true; btn.textContent = 'Resetting...';

    try {
        const d = await post('reset_password', { token, password });
        if (d.success) {
            document.getElementById('resetForm').style.display = 'none';
            document.getElementById('successState').style.display = 'block';
            setTimeout(() => window.location.href = 'login.php', 2000);
        } else {
            showMsg(d.error || 'Reset failed. Please try again.', 'error');
            btn.disabled = false; btn.textContent = 'Reset Password';
        }
    } catch {
        showMsg('Connection error. Please try again.', 'error');
        btn.disabled = false; btn.textContent = 'Reset Password';
    }
}

verifyToken();
</script>
</body>
</html>
