<?php
/**
 * ScanWizard — Database Setup
 * Run once to create the users table.
 * Visit: https://scanwizard.robo-wizard.com/setup_db.php
 * DELETE this file after running.
 */
require_once 'includes/config.php';

try {
    $pdo = new PDO(
        'mysql:host=' . DB_HOST . ';dbname=' . DB_NAME . ';charset=' . DB_CHARSET,
        DB_USER, DB_PASS,
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
    );

    $pdo->exec("
        CREATE TABLE IF NOT EXISTS users (
            id          INT AUTO_INCREMENT PRIMARY KEY,
            full_name   VARCHAR(100) NOT NULL,
            email       VARCHAR(255) NOT NULL UNIQUE,
            password    VARCHAR(255) NOT NULL,
            status      ENUM('pending','approved','rejected') DEFAULT 'pending',
            is_admin    TINYINT(1) DEFAULT 0,
            created_at  DATETIME DEFAULT CURRENT_TIMESTAMP,
            approved_at DATETIME NULL,
            INDEX idx_email (email),
            INDEX idx_status (status)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ");

    // Create default admin account (change password after first login!)
    $adminExists = $pdo->query("SELECT COUNT(*) FROM users WHERE is_admin = 1")->fetchColumn();
    if (!$adminExists) {
        $stmt = $pdo->prepare("INSERT INTO users (full_name, email, password, status, is_admin) VALUES (?, ?, ?, 'approved', 1)");
        $stmt->execute(['Admin', ADMIN_EMAIL, password_hash('ScanWizard2025!', PASSWORD_DEFAULT)]);
        echo "Admin account created: " . ADMIN_EMAIL . " / ScanWizard2025!<br>";
        echo "<strong>CHANGE THIS PASSWORD immediately after first login!</strong><br>";
    }

    echo "<br>Database setup complete. <strong>Delete this file now.</strong>";
} catch (PDOException $e) {
    echo "Error: " . $e->getMessage();
}
