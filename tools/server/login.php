<?php
/**
 * ScanWizard — Login / Register
 * Matches Robo-Wizard's login.php design exactly.
 */
session_start();

if (isset($_SESSION['user_id'])) {
    $redirect = $_GET['redirect'] ?? 'index.php';
    header('Location: ' . $redirect);
    exit;
}

$redirect = $_GET['redirect'] ?? '';
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Login — ScanWizard</title>
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

        .tabs {
            display: flex;
            border-bottom: 2px solid var(--border);
        }
        .tab {
            flex: 1; padding: 1rem; text-align: center;
            background: none; border: none; font-size: 1rem;
            font-weight: 600; color: var(--secondary);
            cursor: pointer; transition: all 0.2s;
        }
        .tab.active { color: var(--primary); border-bottom: 2px solid var(--primary); margin-bottom: -2px; }
        .tab:hover:not(.active) { color: var(--dark); background: var(--light); }

        .form-container { padding: 2rem; }
        .form { display: none; }
        .form.active { display: block; }

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

        .forgot-link { text-align: center; margin-top: 1rem; }
        .forgot-link a { color: var(--secondary); text-decoration: none; font-size: 0.9rem; }
        .forgot-link a:hover { color: var(--primary); text-decoration: underline; }

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
            <!-- ScanWizard logo — matches Robo-Wizard SVG style -->
            <svg viewBox="0 0 340 70" xmlns="http://www.w3.org/2000/svg">
                <text x="10" y="50" font-family="Arial Black,sans-serif" font-size="34" font-weight="900" fill="white">SCAN</text>
                <circle cx="130" cy="35" r="10" fill="white" opacity="0.3"/>
                <circle cx="130" cy="35" r="6" fill="#4ade80"/>
                <text x="150" y="50" font-family="Arial,sans-serif" font-size="28" font-weight="700" fill="#fbbf24">WIZARD</text>
                <!-- sparkle stars -->
                <text x="300" y="20" font-size="14" fill="#fbbf24">✦</text>
                <text x="318" y="38" font-size="10" fill="#fbbf24">✦</text>
            </svg>
        </div>
        <p>Your private LiDAR scan lab</p>
    </div>

    <div class="tabs">
        <button class="tab active" onclick="switchTab('login')">Login</button>
        <button class="tab" onclick="switchTab('register')">Register</button>
    </div>

    <div class="form-container">
        <div id="message" class="message"></div>

        <!-- Login -->
        <form id="loginForm" class="form active" onsubmit="handleLogin(event)">
            <div class="form-group">
                <label for="loginEmail">Email Address</label>
                <input type="email" id="loginEmail" name="email" required autocomplete="email">
            </div>
            <div class="form-group">
                <label for="loginPassword">Password</label>
                <div class="password-wrapper">
                    <input type="password" id="loginPassword" name="password" required autocomplete="current-password">
                    <button type="button" class="password-toggle" onclick="togglePassword('loginPassword',this)" aria-label="Show password">
                        <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"/>
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"/>
                        </svg>
                    </button>
                </div>
            </div>
            <button type="submit" class="btn btn-primary" id="loginBtn">Login</button>
            <div class="forgot-link">
                <a href="#" onclick="showForgot(event)">Forgot Password?</a>
            </div>
        </form>

        <!-- Forgot Password -->
        <form id="forgotForm" class="form" onsubmit="handleForgot(event)">
            <p style="color:var(--secondary);margin-bottom:1.25rem;font-size:0.95rem;">
                Enter your email and we'll send you a reset link.
            </p>
            <div class="form-group">
                <label for="forgotEmail">Email Address</label>
                <input type="email" id="forgotEmail" required autocomplete="email">
            </div>
            <button type="submit" class="btn btn-primary" id="forgotBtn">Send Reset Link</button>
            <div class="forgot-link"><a href="#" onclick="backToLogin(event)">Back to Login</a></div>
        </form>

        <!-- Register -->
        <form id="registerForm" class="form" onsubmit="handleRegister(event)">
            <div class="form-group">
                <label for="regName">Full Name</label>
                <input type="text" id="regName" required autocomplete="name">
            </div>
            <div class="form-group">
                <label for="regEmail">Email Address</label>
                <input type="email" id="regEmail" required autocomplete="email">
            </div>
            <div class="form-group">
                <label for="regCompany">Company (Optional)</label>
                <input type="text" id="regCompany" autocomplete="organization">
            </div>
            <div class="form-group">
                <label for="regPassword">Password</label>
                <div class="password-wrapper">
                    <input type="password" id="regPassword" required minlength="6" autocomplete="new-password">
                    <button type="button" class="password-toggle" onclick="togglePassword('regPassword',this)" aria-label="Show password">
                        <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"/>
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"/>
                        </svg>
                    </button>
                </div>
                <small>Minimum 6 characters</small>
            </div>
            <button type="submit" class="btn btn-primary" id="registerBtn">Create Account</button>
        </form>

        <div class="back-link">
            <a href="https://robo-wizard.com">← Back to Robo-Wizard</a>
        </div>
    </div>
</div>

<script>
const redirect = <?= json_encode($redirect) ?>;

function togglePassword(id, btn) {
    const input = document.getElementById(id);
    const isHidden = input.type === 'password';
    input.type = isHidden ? 'text' : 'password';
    btn.innerHTML = isHidden
        ? '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13.875 18.825A10.05 10.05 0 0112 19c-4.478 0-8.268-2.943-9.543-7a9.97 9.97 0 011.563-3.029m5.858.908a3 3 0 114.243 4.243M9.878 9.878l4.242 4.242M9.88 9.88l-3.29-3.29m7.532 7.532l3.29 3.29M3 3l3.59 3.59m0 0A9.953 9.953 0 0112 5c4.478 0 8.268 2.943 9.543 7a10.025 10.025 0 01-4.132 5.411m0 0L21 21"/></svg>'
        : '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"/><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"/></svg>';
    btn.setAttribute('aria-label', isHidden ? 'Hide password' : 'Show password');
}

function switchTab(tab) {
    document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
    document.querySelectorAll('.form').forEach(f => f.classList.remove('active'));
    const isLogin = tab === 'login';
    document.querySelector('.tab:' + (isLogin ? 'first-child' : 'last-child')).classList.add('active');
    document.getElementById(isLogin ? 'loginForm' : 'registerForm').classList.add('active');
    hideMsg();
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

async function handleLogin(e) {
    e.preventDefault();
    const btn = document.getElementById('loginBtn');
    btn.disabled = true; btn.textContent = 'Logging in…';
    hideMsg();
    try {
        const d = await post('login', {
            email: document.getElementById('loginEmail').value,
            password: document.getElementById('loginPassword').value
        });
        if (d.success) {
            showMsg('Login successful! Redirecting…', 'success');
            setTimeout(() => window.location.href = redirect || 'index.php', 500);
        } else {
            showMsg(d.error || 'Login failed', 'error');
            btn.disabled = false; btn.textContent = 'Login';
        }
    } catch { showMsg('Connection error. Please try again.', 'error'); btn.disabled = false; btn.textContent = 'Login'; }
}

async function handleRegister(e) {
    e.preventDefault();
    const btn = document.getElementById('registerBtn');
    btn.disabled = true; btn.textContent = 'Creating account…';
    hideMsg();
    try {
        const d = await post('register', {
            full_name: document.getElementById('regName').value,
            email: document.getElementById('regEmail').value,
            company: document.getElementById('regCompany').value,
            password: document.getElementById('regPassword').value
        });
        if (d.success) {
            showMsg('Account created! Redirecting…', 'success');
            setTimeout(() => window.location.href = redirect || 'index.php', 500);
        } else {
            showMsg(d.error || 'Registration failed', 'error');
            btn.disabled = false; btn.textContent = 'Create Account';
        }
    } catch { showMsg('Connection error.', 'error'); btn.disabled = false; btn.textContent = 'Create Account'; }
}

function showForgot(e) {
    e.preventDefault();
    document.querySelectorAll('.tab, .form').forEach(el => el.classList.remove('active'));
    document.getElementById('forgotForm').classList.add('active');
    hideMsg();
}
function backToLogin(e) {
    e.preventDefault();
    document.querySelectorAll('.form').forEach(f => f.classList.remove('active'));
    document.getElementById('loginForm').classList.add('active');
    document.querySelector('.tab:first-child').classList.add('active');
    hideMsg();
}

async function handleForgot(e) {
    e.preventDefault();
    const btn = document.getElementById('forgotBtn');
    btn.disabled = true; btn.textContent = 'Sending…';
    hideMsg();
    try {
        const d = await post('forgot_password', { email: document.getElementById('forgotEmail').value });
        if (d.success) { showMsg(d.message || 'Reset link sent! Check your email.', 'success'); btn.textContent = 'Sent ✓'; }
        else { showMsg(d.error || 'Failed', 'error'); btn.disabled = false; btn.textContent = 'Send Reset Link'; }
    } catch { showMsg('Connection error.', 'error'); btn.disabled = false; btn.textContent = 'Send Reset Link'; }
}
</script>
</body>
</html>
