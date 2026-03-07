<?php
/**
 * ScanWizard — Auth API
 * POST actions: login, register, logout, approve, reject
 */
session_start();
require_once '../includes/db.php';

header('Content-Type: application/json');

$input  = json_decode(file_get_contents('php://input'), true) ?? [];
$action = $input['action'] ?? '';

switch ($action) {
    case 'login':    handleLogin($input); break;
    case 'register': handleRegister($input); break;
    case 'logout':   handleLogout(); break;
    case 'approve':  handleApproval($input, 'approved'); break;
    case 'reject':   handleApproval($input, 'rejected'); break;
    case 'list_users': handleListUsers(); break;
    default:
        echo json_encode(['success' => false, 'error' => 'Invalid action']);
}

function handleLogin(array $input): void {
    $email    = trim($input['email'] ?? '');
    $password = $input['password'] ?? '';

    if (!$email || !$password) {
        echo json_encode(['success' => false, 'error' => 'Email and password required']);
        return;
    }

    $db   = getDB();
    $stmt = $db->prepare("SELECT * FROM users WHERE email = ?");
    $stmt->execute([$email]);
    $user = $stmt->fetch();

    if (!$user || !password_verify($password, $user['password'])) {
        echo json_encode(['success' => false, 'error' => 'Invalid email or password']);
        return;
    }

    if ($user['status'] === 'pending') {
        echo json_encode(['success' => false, 'error' => 'Your account is awaiting approval. You will receive an email once approved.']);
        return;
    }

    if ($user['status'] === 'rejected') {
        echo json_encode(['success' => false, 'error' => 'Your registration was not approved.']);
        return;
    }

    $_SESSION['user_id'] = $user['id'];
    $_SESSION['user']    = [
        'id'        => $user['id'],
        'full_name' => $user['full_name'],
        'email'     => $user['email'],
        'is_admin'  => (bool)$user['is_admin'],
    ];

    echo json_encode(['success' => true, 'user' => $_SESSION['user']]);
}

function handleRegister(array $input): void {
    $name     = trim($input['full_name'] ?? '');
    $email    = trim($input['email'] ?? '');
    $password = $input['password'] ?? '';

    if (!$name || !$email || !$password) {
        echo json_encode(['success' => false, 'error' => 'All fields are required']);
        return;
    }

    if (strlen($password) < 6) {
        echo json_encode(['success' => false, 'error' => 'Password must be at least 6 characters']);
        return;
    }

    if (!filter_var($email, FILTER_VALIDATE_EMAIL)) {
        echo json_encode(['success' => false, 'error' => 'Invalid email address']);
        return;
    }

    $db = getDB();

    // Check if email already exists
    $stmt = $db->prepare("SELECT id FROM users WHERE email = ?");
    $stmt->execute([$email]);
    if ($stmt->fetch()) {
        echo json_encode(['success' => false, 'error' => 'Email already registered']);
        return;
    }

    $hash = password_hash($password, PASSWORD_DEFAULT);
    $stmt = $db->prepare("INSERT INTO users (full_name, email, password, status) VALUES (?, ?, ?, 'pending')");
    $stmt->execute([$name, $email, $hash]);

    // Email admin about new registration
    $approveUrl = APP_URL . '/admin.php';
    $subject    = "[ScanWizard] New registration: $name";
    $body       = "New user registration:\n\n"
                . "Name:  $name\n"
                . "Email: $email\n"
                . "Time:  " . date('Y-m-d H:i:s') . " UTC\n\n"
                . "Review and approve at:\n$approveUrl\n";
    $headers    = "From: noreply@scanwizard.robo-wizard.com\r\n"
                . "Reply-To: " . ADMIN_EMAIL . "\r\n";

    @mail(ADMIN_EMAIL, $subject, $body, $headers);

    echo json_encode([
        'success' => true,
        'message' => 'Registration submitted. You will receive an email once your account is approved.'
    ]);
}

function handleLogout(): void {
    session_destroy();
    echo json_encode(['success' => true]);
}

function handleApproval(array $input, string $status): void {
    // Admin only
    if (!isset($_SESSION['user']) || !$_SESSION['user']['is_admin']) {
        http_response_code(403);
        echo json_encode(['success' => false, 'error' => 'Admin access required']);
        return;
    }

    $userId = (int)($input['user_id'] ?? 0);
    if (!$userId) {
        echo json_encode(['success' => false, 'error' => 'User ID required']);
        return;
    }

    $db = getDB();
    $stmt = $db->prepare("UPDATE users SET status = ?, approved_at = NOW() WHERE id = ?");
    $stmt->execute([$status, $userId]);

    // Notify user by email
    $stmt = $db->prepare("SELECT full_name, email FROM users WHERE id = ?");
    $stmt->execute([$userId]);
    $user = $stmt->fetch();

    if ($user) {
        if ($status === 'approved') {
            $subject = "[ScanWizard] Your account has been approved";
            $body    = "Hi {$user['full_name']},\n\n"
                     . "Your ScanWizard account has been approved!\n\n"
                     . "You can now log in at:\n" . APP_URL . "/login.php\n\n"
                     . "— ScanWizard Team";
        } else {
            $subject = "[ScanWizard] Registration update";
            $body    = "Hi {$user['full_name']},\n\n"
                     . "Unfortunately, your ScanWizard registration was not approved at this time.\n\n"
                     . "— ScanWizard Team";
        }
        $headers = "From: noreply@scanwizard.robo-wizard.com\r\n";
        @mail($user['email'], $subject, $body, $headers);
    }

    echo json_encode(['success' => true, 'status' => $status]);
}

function handleListUsers(): void {
    if (!isset($_SESSION['user']) || !$_SESSION['user']['is_admin']) {
        http_response_code(403);
        echo json_encode(['success' => false, 'error' => 'Admin access required']);
        return;
    }

    $db    = getDB();
    $users = $db->query("SELECT id, full_name, email, status, is_admin, created_at, approved_at FROM users ORDER BY created_at DESC")->fetchAll();
    echo json_encode(['success' => true, 'users' => $users]);
}
