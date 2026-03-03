<?php
/**
 * ScanWizard — Auth API
 * Adapted from Robo-Wizard's api/auth.php — identical logic, ScanWizard branding.
 */
session_start();
require_once '../includes/config.php';
require_once '../includes/Database.php';

header('Content-Type: application/json');

$input  = json_decode(file_get_contents('php://input'), true) ?? [];
$action = $input['action'] ?? '';

$db = Database::getInstance();

// Create tables if needed
try {
    $db->query("
        CREATE TABLE IF NOT EXISTS users (
            id            INT AUTO_INCREMENT PRIMARY KEY,
            email         VARCHAR(255) NOT NULL UNIQUE,
            full_name     VARCHAR(255) NOT NULL,
            company       VARCHAR(255),
            password_hash VARCHAR(255) NOT NULL,
            created_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            last_login    TIMESTAMP NULL,
            INDEX idx_email (email)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ");
    $db->query("
        CREATE TABLE IF NOT EXISTS password_reset_tokens (
            id         INT AUTO_INCREMENT PRIMARY KEY,
            user_id    INT NOT NULL,
            token      VARCHAR(64) NOT NULL UNIQUE,
            expires_at TIMESTAMP NOT NULL,
            used       TINYINT(1) DEFAULT 0,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            INDEX idx_token (token),
            INDEX idx_user_id (user_id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ");
} catch (Exception $e) { /* already exist */ }

switch ($action) {
    case 'register':        handleRegister($db, $input);     break;
    case 'login':           handleLogin($db, $input);        break;
    case 'logout':          handleLogout();                  break;
    case 'forgot_password': handleForgotPassword($db,$input);break;
    case 'reset_password':  handleResetPassword($db,$input); break;
    case 'verify_reset_token': handleVerifyToken($db,$input);break;
    default: echo json_encode(['success'=>false,'error'=>'Invalid action']);
}

// ── Handlers ────────────────────────────────────────────────────────────────

function handleRegister($db, $input) {
    $email    = trim($input['email']     ?? '');
    $fullName = trim($input['full_name'] ?? '');
    $company  = trim($input['company']   ?? '');
    $password = $input['password']       ?? '';

    if (!$email || !filter_var($email, FILTER_VALIDATE_EMAIL))
        return out(false, 'Please enter a valid email address.');
    if (strlen($fullName) < 2)
        return out(false, 'Please enter your full name.');
    if (strlen($password) < 6)
        return out(false, 'Password must be at least 6 characters.');
    if ($db->fetchOne("SELECT id FROM users WHERE email=?", [$email]))
        return out(false, 'An account with this email already exists.');

    $hash = password_hash($password, PASSWORD_DEFAULT);
    try {
        $db->query("INSERT INTO users (email,full_name,company,password_hash) VALUES (?,?,?,?)",
            [$email, $fullName, $company, $hash]);
        $id = $db->lastInsertId();
        startSession($id, $email, $fullName, $company);
        out(true, 'Account created successfully.');
    } catch (Exception $e) { out(false, 'Registration failed. Please try again.'); }
}

function handleLogin($db, $input) {
    $email    = trim($input['email']    ?? '');
    $password = $input['password'] ?? '';

    if (!$email || !$password)
        return out(false, 'Please enter email and password.');

    $user = $db->fetchOne("SELECT * FROM users WHERE email=?", [$email]);
    if (!$user || !password_verify($password, $user['password_hash']))
        return out(false, 'Invalid email or password.');

    $db->query("UPDATE users SET last_login=NOW() WHERE id=?", [$user['id']]);
    startSession($user['id'], $user['email'], $user['full_name'], $user['company']);
    out(true, 'Login successful.');
}

function handleLogout() {
    session_destroy();
    out(true, 'Logged out.');
}

function handleForgotPassword($db, $input) {
    $email = trim($input['email'] ?? '');
    if (!filter_var($email, FILTER_VALIDATE_EMAIL))
        return out(false, 'Please enter a valid email address.');

    $user = $db->fetchOne("SELECT id,full_name FROM users WHERE email=?", [$email]);
    if (!$user)
        return out(true, 'If an account exists with this email, a reset link has been sent.');

    $token     = bin2hex(random_bytes(32));
    $expiresAt = date('Y-m-d H:i:s', strtotime('+1 hour'));
    $db->query("DELETE FROM password_reset_tokens WHERE user_id=?", [$user['id']]);
    $db->query("INSERT INTO password_reset_tokens (user_id,token,expires_at) VALUES (?,?,?)",
        [$user['id'], $token, $expiresAt]);

    $proto    = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS']!=='off') ? 'https' : 'http';
    $host     = $_SERVER['HTTP_HOST'];
    $base     = dirname(dirname($_SERVER['REQUEST_URI']));
    $resetUrl = "$proto://$host$base/reset-password.php?token=$token";

    $sent = sendResetEmail($email, $user['full_name'], $resetUrl);
    if ($sent) {
        out(true, 'Password reset link has been sent to your email.');
    } else {
        out(true, 'Email could not be sent. Use this link:', ['reset_url' => $resetUrl]);
    }
}

function sendResetEmail($email, $name, $url) {
    $subject = "Password Reset — ScanWizard";
    $body = "
    <html><head><style>
        body{font-family:Arial,sans-serif;color:#333}
        .header{background:linear-gradient(135deg,#3b82f6,#1d4ed8);color:white;padding:20px;text-align:center;border-radius:8px 8px 0 0}
        .content{background:#f8fafc;padding:30px;border-radius:0 0 8px 8px}
        .btn{display:inline-block;background:#3b82f6;color:white;padding:12px 24px;text-decoration:none;border-radius:6px;margin:20px 0}
    </style></head><body>
    <div class='header'><h1>Password Reset</h1></div>
    <div class='content'>
        <p>Hi {$name},</p>
        <p>Click below to reset your ScanWizard password:</p>
        <p><a href='{$url}' class='btn'>Reset Password</a></p>
        <p style='word-break:break-all;color:#3b82f6'>{$url}</p>
        <p>This link expires in 1 hour.</p>
        <p>— The ScanWizard Team</p>
    </div></body></html>";

    $headers  = "MIME-Version: 1.0\r\n";
    $headers .= "Content-type: text/html; charset=UTF-8\r\n";
    $headers .= "From: ScanWizard <noreply@robo-wizard.com>\r\n";
    return @mail($email, $subject, $body, $headers);
}

function handleVerifyToken($db, $input) {
    $token = trim($input['token'] ?? '');
    if (!$token) return out(false, 'Invalid token.');
    $t = $db->fetchOne("SELECT * FROM password_reset_tokens WHERE token=? AND used=0 AND expires_at>NOW()", [$token]);
    $t ? out(true, 'Token valid.') : out(false, 'Reset link is invalid or has expired.');
}

function handleResetPassword($db, $input) {
    $token    = trim($input['token']    ?? '');
    $password = $input['password'] ?? '';
    if (!$token) return out(false, 'Invalid token.');
    if (strlen($password) < 6) return out(false, 'Password must be at least 6 characters.');

    $t = $db->fetchOne("SELECT * FROM password_reset_tokens WHERE token=? AND used=0 AND expires_at>NOW()", [$token]);
    if (!$t) return out(false, 'Reset link is invalid or has expired.');

    $hash = password_hash($password, PASSWORD_DEFAULT);
    $db->query("UPDATE users SET password_hash=? WHERE id=?", [$hash, $t['user_id']]);
    $db->query("UPDATE password_reset_tokens SET used=1 WHERE id=?", [$t['id']]);
    out(true, 'Password reset successfully. You can now login.');
}

// ── Helpers ─────────────────────────────────────────────────────────────────

function startSession($id, $email, $fullName, $company) {
    $_SESSION['user_id'] = $id;
    $_SESSION['user']    = compact('id','email','full_name','company') +
                           ['full_name' => $fullName];
}

function out(bool $success, string $message, array $extra = []): void {
    echo json_encode(array_merge(
        ['success' => $success, $success ? 'message' : 'error' => $message],
        $extra
    ));
    exit;
}
