-- ============================================================
-- Automobile Manufacturing Dashboard - MySQL schema
-- Run this once against your RDS instance:
--   mysql -h <DB_HOST> -u <DB_USER> -p <DB_NAME> < schema.sql
-- ============================================================

CREATE TABLE IF NOT EXISTS users (
    id            INT AUTO_INCREMENT PRIMARY KEY,
    username      VARCHAR(64)  NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    created_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS materials (
    id             INT AUTO_INCREMENT PRIMARY KEY,
    name           VARCHAR(128) NOT NULL,
    material_type  VARCHAR(64)  NOT NULL,
    produced       INT NOT NULL DEFAULT 0,
    assembled      INT NOT NULL DEFAULT 0,
    delivered      INT NOT NULL DEFAULT 0,
    created_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS production_log (
    id           INT AUTO_INCREMENT PRIMARY KEY,
    material_id  INT NOT NULL,
    quantity     INT NOT NULL,
    log_date     DATE NOT NULL,
    FOREIGN KEY (material_id) REFERENCES materials(id) ON DELETE CASCADE
);

CREATE INDEX idx_production_log_date ON production_log(log_date);

-- ------------------------------------------------------------
-- Seed an initial admin user.
-- The password hash below corresponds to password: Admin@123
-- Generate your own with:
--   python3 -c "import bcrypt; print(bcrypt.hashpw(b'YourPassword', bcrypt.gensalt()).decode())"
-- and replace it before running in a real environment.
-- ------------------------------------------------------------
INSERT INTO users (username, password_hash)
VALUES ('admin', '$2b$12$replace_with_output_of_the_bcrypt_command_above')
ON DUPLICATE KEY UPDATE username = username;
