"""
Automobile Manufacturing Unit Dashboard
----------------------------------------
Two-tier Flask application (app tier) backed by MySQL / AWS RDS (data tier).

Environment variables required (set these as Kubernetes Secrets / env vars,
NEVER hardcode them):
    DB_HOST       - RDS endpoint, e.g. automobile-db.xxxxxx.ap-south-1.rds.amazonaws.com
    DB_PORT       - default 3306
    DB_USER       - RDS master/app username
    DB_PASSWORD   - RDS password
    DB_NAME       - database name, e.g. automobile_db
    SECRET_KEY    - random string used to sign Flask session cookies
"""

import os
import datetime
from functools import wraps

import pymysql
import pymysql.cursors
import bcrypt
from flask import (
    Flask, render_template, request, redirect,
    url_for, session, flash, jsonify
)
from prometheus_flask_exporter import PrometheusMetrics

app = Flask(__name__)
app.secret_key = os.environ.get("SECRET_KEY", "change-this-in-prod")

# ---------------------------------------------------------------------------
# Prometheus metrics endpoint -> exposes /metrics for Prometheus to scrape
# ---------------------------------------------------------------------------
metrics = PrometheusMetrics(app)
metrics.info("app_info", "Automobile Manufacturing Dashboard", version="1.0.0")

# ---------------------------------------------------------------------------
# Database connection helper
# ---------------------------------------------------------------------------
DB_CONFIG = {
    "host": os.environ.get("DB_HOST", "localhost"),
    "port": int(os.environ.get("DB_PORT", 3306)),
    "user": os.environ.get("DB_USER", "admin"),
    "password": os.environ.get("DB_PASSWORD", ""),
    "database": os.environ.get("DB_NAME", "automobile_db"),
    "cursorclass": pymysql.cursors.DictCursor,
    "connect_timeout": 5,
}


def get_db():
    """Open a fresh connection for this request. Closed explicitly after use."""
    return pymysql.connect(**DB_CONFIG)


# ---------------------------------------------------------------------------
# Auth helpers
# ---------------------------------------------------------------------------
def login_required(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        if "user_id" not in session:
            return redirect(url_for("login"))
        return f(*args, **kwargs)
    return wrapper


# ---------------------------------------------------------------------------
# Health endpoints (used by Kubernetes liveness / readiness probes and ALB
# target group health checks)
# ---------------------------------------------------------------------------
@app.route("/healthz")
def healthz():
    """Liveness probe - just confirms the process is alive, no DB call."""
    return jsonify(status="ok"), 200


@app.route("/readyz")
def readyz():
    """Readiness probe - confirms the app can actually reach the database."""
    try:
        conn = get_db()
        conn.close()
        return jsonify(status="ready"), 200
    except Exception as e:
        return jsonify(status="not-ready", error=str(e)), 503


# ---------------------------------------------------------------------------
# Auth routes
# ---------------------------------------------------------------------------
@app.route("/", methods=["GET"])
def index():
    return redirect(url_for("login"))


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "").encode("utf-8")

        conn = get_db()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT id, username, password_hash FROM users WHERE username=%s",
                    (username,),
                )
                user = cur.fetchone()
        finally:
            conn.close()

        if user and bcrypt.checkpw(password, user["password_hash"].encode("utf-8")):
            session["user_id"] = user["id"]
            session["username"] = user["username"]
            return redirect(url_for("dashboard"))

        flash("Invalid username or password", "error")
        return render_template("login.html")

    return render_template("login.html")


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


# ---------------------------------------------------------------------------
# Dashboard
# ---------------------------------------------------------------------------
@app.route("/dashboard")
@login_required
def dashboard():
    conn = get_db()
    try:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT
                    COALESCE(SUM(produced), 0)  AS total_produced,
                    COALESCE(SUM(assembled), 0) AS total_assembled,
                    COALESCE(SUM(delivered), 0) AS total_delivered,
                    COALESCE(SUM(GREATEST(produced - assembled, 0)), 0) AS pending_assembly,
                    COALESCE(SUM(GREATEST(assembled - delivered, 0)), 0) AS pending_delivery,
                    COUNT(*) AS material_types
                FROM materials
            """)
            totals = cur.fetchone()

            cur.execute("""
                SELECT COALESCE(SUM(quantity), 0) AS today_count
                FROM production_log
                WHERE log_date = CURDATE()
            """)
            today_count = cur.fetchone()["today_count"]

            cur.execute("""
                SELECT COALESCE(SUM(quantity), 0) AS month_count
                FROM production_log
                WHERE YEAR(log_date) = YEAR(CURDATE())
                  AND MONTH(log_date) = MONTH(CURDATE())
            """)
            month_count = cur.fetchone()["month_count"]

            # Last 7 days production trend
            cur.execute("""
                SELECT log_date, SUM(quantity) AS qty
                FROM production_log
                WHERE log_date >= CURDATE() - INTERVAL 6 DAY
                GROUP BY log_date
                ORDER BY log_date ASC
            """)
            trend_rows = cur.fetchall()
    finally:
        conn.close()

    # Build a full 7-day series (fill days with 0 where there's no data)
    trend_map = {row["log_date"].isoformat(): row["qty"] for row in trend_rows}
    trend_labels, trend_values = [], []
    for i in range(6, -1, -1):
        d = (datetime.date.today() - datetime.timedelta(days=i)).isoformat()
        trend_labels.append(d)
        trend_values.append(int(trend_map.get(d, 0)))

    return render_template(
        "dashboard.html",
        totals=totals,
        today_count=today_count,
        month_count=month_count,
        trend_labels=trend_labels,
        trend_values=trend_values,
        username=session.get("username"),
        year=datetime.date.today().year,
    )


# ---------------------------------------------------------------------------
# Materials list + progress update
# ---------------------------------------------------------------------------
@app.route("/materials")
@login_required
def materials():
    conn = get_db()
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT * FROM materials ORDER BY created_at DESC")
            rows = cur.fetchall()
    finally:
        conn.close()
    return render_template("materials.html", materials=rows, username=session.get("username"))


@app.route("/materials/<int:material_id>/update", methods=["POST"])
@login_required
def update_material(material_id):
    """Increment assembled / delivered counts for an existing material."""
    assembled_delta = int(request.form.get("assembled_delta", 0) or 0)
    delivered_delta = int(request.form.get("delivered_delta", 0) or 0)

    conn = get_db()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE materials
                SET assembled = LEAST(produced, assembled + %s),
                    delivered = LEAST(assembled, delivered + %s)
                WHERE id = %s
                """,
                (assembled_delta, delivered_delta, material_id),
            )
        conn.commit()
    finally:
        conn.close()

    flash("Material progress updated", "success")
    return redirect(url_for("materials"))


# ---------------------------------------------------------------------------
# Add Material
# ---------------------------------------------------------------------------
@app.route("/add-material", methods=["GET", "POST"])
@login_required
def add_material():
    if request.method == "POST":
        name = request.form.get("name", "").strip()
        material_type = request.form.get("material_type", "").strip()
        produced = int(request.form.get("produced", 0) or 0)

        if not name or not material_type:
            flash("Material name and type are required", "error")
            return render_template("add_material.html")

        conn = get_db()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO materials (name, material_type, produced, assembled, delivered)
                    VALUES (%s, %s, %s, 0, 0)
                    """,
                    (name, material_type, produced),
                )
                if produced > 0:
                    cur.execute(
                        "INSERT INTO production_log (material_id, quantity, log_date) "
                        "VALUES (%s, %s, CURDATE())",
                        (cur.lastrowid, produced),
                    )
            conn.commit()
        finally:
            conn.close()

        flash(f'Material "{name}" added successfully', "success")
        return redirect(url_for("materials"))

    return render_template("add_material.html", username=session.get("username"))


# ---------------------------------------------------------------------------
# Production Tracking
# ---------------------------------------------------------------------------
@app.route("/production-tracking", methods=["GET", "POST"])
@login_required
def production_tracking():
    conn = get_db()
    try:
        if request.method == "POST":
            material_id = int(request.form.get("material_id"))
            quantity = int(request.form.get("quantity", 0) or 0)
            with conn.cursor() as cur:
                cur.execute(
                    "UPDATE materials SET produced = produced + %s WHERE id = %s",
                    (quantity, material_id),
                )
                cur.execute(
                    "INSERT INTO production_log (material_id, quantity, log_date) "
                    "VALUES (%s, %s, CURDATE())",
                    (material_id, quantity),
                )
            conn.commit()
            flash("Production logged", "success")
            return redirect(url_for("production_tracking"))

        with conn.cursor() as cur:
            cur.execute("SELECT id, name FROM materials ORDER BY name")
            materials_list = cur.fetchall()
            cur.execute("""
                SELECT pl.log_date, m.name, pl.quantity
                FROM production_log pl
                JOIN materials m ON m.id = pl.material_id
                ORDER BY pl.log_date DESC, pl.id DESC
                LIMIT 25
            """)
            recent_logs = cur.fetchall()
    finally:
        conn.close()

    return render_template(
        "production_tracking.html",
        materials=materials_list,
        logs=recent_logs,
        username=session.get("username"),
    )


# ---------------------------------------------------------------------------
# Inventory
# ---------------------------------------------------------------------------
@app.route("/inventory")
@login_required
def inventory():
    conn = get_db()
    try:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT name, material_type,
                       (produced - delivered) AS in_stock,
                       produced, assembled, delivered
                FROM materials
                ORDER BY name
            """)
            rows = cur.fetchall()
    finally:
        conn.close()
    return render_template("inventory.html", inventory=rows, username=session.get("username"))


# ---------------------------------------------------------------------------
# Reports
# ---------------------------------------------------------------------------
@app.route("/reports")
@login_required
def reports():
    conn = get_db()
    try:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT log_date, SUM(quantity) AS total_qty
                FROM production_log
                GROUP BY log_date
                ORDER BY log_date DESC
                LIMIT 30
            """)
            daily_report = cur.fetchall()
    finally:
        conn.close()
    return render_template("reports.html", report=daily_report, username=session.get("username"))


# ---------------------------------------------------------------------------
# Profile
# ---------------------------------------------------------------------------
@app.route("/profile")
@login_required
def profile():
    return render_template("profile.html", username=session.get("username"))


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
