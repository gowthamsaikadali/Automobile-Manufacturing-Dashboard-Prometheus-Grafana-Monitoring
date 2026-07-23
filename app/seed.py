"""
Run once after RDS is up to create schema + the initial admin user.
Reads DB creds from env vars (same ones the app uses).

Usage (from GitHub Actions or locally with env vars exported):
    python seed.py
"""
import os
import sys
import pymysql
import bcrypt

DB_HOST = os.environ["DB_HOST"]
DB_USER = os.environ["DB_USER"]
DB_PASSWORD = os.environ["DB_PASSWORD"]
DB_NAME = os.environ.get("DB_NAME", "autoforge")
DB_PORT = int(os.environ.get("DB_PORT", "3306"))

ADMIN_USER = os.environ.get("ADMIN_USERNAME", "admin")
ADMIN_PASS = os.environ.get("ADMIN_PASSWORD")

if not ADMIN_PASS:
    print("ERROR: ADMIN_PASSWORD env var is required to seed the admin user.")
    sys.exit(1)

conn = pymysql.connect(host=DB_HOST, user=DB_USER, password=DB_PASSWORD,
                        port=DB_PORT, connect_timeout=10)

with conn.cursor() as cur:
    cur.execute(f"CREATE DATABASE IF NOT EXISTS `{DB_NAME}`")
conn.select_db(DB_NAME)

with conn.cursor() as cur:
    cur.execute("""
        CREATE TABLE IF NOT EXISTS users (
            id INT AUTO_INCREMENT PRIMARY KEY,
            username VARCHAR(64) UNIQUE NOT NULL,
            password_hash VARCHAR(255) NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    """)
    cur.execute("""
        CREATE TABLE IF NOT EXISTS materials (
            id INT AUTO_INCREMENT PRIMARY KEY,
            material_name VARCHAR(128) NOT NULL,
            quantity_produced INT DEFAULT 0,
            quantity_assembled INT DEFAULT 0,
            quantity_delivered INT DEFAULT 0,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
        )
    """)
    cur.execute("""
        CREATE TABLE IF NOT EXISTS production_log (
            id INT AUTO_INCREMENT PRIMARY KEY,
            material_id INT,
            quantity_produced INT DEFAULT 0,
            log_date DATE NOT NULL,
            FOREIGN KEY (material_id) REFERENCES materials(id) ON DELETE SET NULL
        )
    """)

    pw_hash = bcrypt.hashpw(ADMIN_PASS.encode("utf-8"), bcrypt.gensalt()).decode("utf-8")
    cur.execute("""
        INSERT INTO users (username, password_hash) VALUES (%s, %s)
        ON DUPLICATE KEY UPDATE password_hash = VALUES(password_hash)
    """, (ADMIN_USER, pw_hash))

conn.commit()
conn.close()
print(f"Seed complete. Admin user '{ADMIN_USER}' is ready.")
