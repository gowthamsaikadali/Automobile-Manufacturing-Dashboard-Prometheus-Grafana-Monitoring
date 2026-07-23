import os
import functools
import datetime
from flask import Flask, render_template, request, redirect, url_for, session, jsonify
import pymysql
import bcrypt

app = Flask(__name__)
app.secret_key = os.environ.get("FLASK_SECRET_KEY", "change-me-in-prod")

# ---------------------------------------------------------------------------
# DB CONFIG - pulled from environment variables (injected via K8s Secret /
# External Secrets Operator in the cluster, or a local .env when testing)
# ---------------------------------------------------------------------------
DB_HOST = os.environ.get("DB_HOST")
DB_USER = os.environ.get("DB_USER")
DB_PASSWORD = os.environ.get("DB_PASSWORD")
DB_NAME = os.environ.get("DB_NAME", "autoforge")
DB_PORT = int(os.environ.get("DB_PORT", "3306"))


def get_db_connection():
    return pymysql.connect(
        host=DB_HOST,
        user=DB_USER,
        password=DB_PASSWORD,
        database=DB_NAME,
        port=DB_PORT,
        cursorclass=pymysql.cursors.DictCursor,
        connect_timeout=5,
    )


def login_required(view):
    @functools.wraps(view)
    def wrapped(*args, **kwargs):
        if not session.get("user"):
            return redirect(url_for("login"))
        return view(*args, **kwargs)
    return wrapped


# ---------------------------------------------------------------------------
# HEALTH / METRICS - used by ALB target group health checks and Prometheus
# ---------------------------------------------------------------------------
@app.route("/healthz")
def healthz():
    try:
        conn = get_db_connection()
        conn.close()
        return jsonify(status="ok", db="connected"), 200
    except Exception as e:
        return jsonify(status="degraded", db="unreachable", error=str(e)), 200


@app.route("/readyz")
def readyz():
    return jsonify(status="ready"), 200


# ---------------------------------------------------------------------------
# AUTH
# ---------------------------------------------------------------------------
@app.route("/", methods=["GET"])
def root():
    if session.get("user"):
        return redirect(url_for("dashboard"))
    return redirect(url_for("login"))


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "GET":
        return render_template("login.html", error=None)

    username = request.form.get("username", "").strip()
    password = request.form.get("password", "")

    if not username or not password:
        return render_template("login.html", error="Username and password are required.")

    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            cur.execute("SELECT id, username, password_hash FROM users WHERE username=%s", (username,))
            row = cur.fetchone()
        conn.close()
    except Exception as e:
        return render_template("login.html", error=f"Database error: {e}")

    if row and bcrypt.checkpw(password.encode("utf-8"), row["password_hash"].encode("utf-8")):
        session["user"] = row["username"]
        return redirect(url_for("dashboard"))

    return render_template("login.html", error="Invalid username or password.")


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


# ---------------------------------------------------------------------------
# DASHBOARD
# ---------------------------------------------------------------------------
@app.route("/dashboard")
@login_required
def dashboard():
    stats = {
        "total_produced": 0,
        "total_assembled": 0,
        "total_delivered": 0,
        "pending_assembly": 0,
        "pending_delivery": 0,
        "material_types": 0,
        "daily_production": 0,
        "monthly_production": 0,
    }
    trend_labels, trend_values = [], []
    assembled_total, delivered_total = 0, 0

    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            cur.execute("SELECT COALESCE(SUM(quantity_produced),0) AS v FROM materials")
            stats["total_produced"] = cur.fetchone()["v"]

            cur.execute("SELECT COALESCE(SUM(quantity_assembled),0) AS v FROM materials")
            stats["total_assembled"] = cur.fetchone()["v"]
            assembled_total = stats["total_assembled"]

            cur.execute("SELECT COALESCE(SUM(quantity_delivered),0) AS v FROM materials")
            stats["total_delivered"] = cur.fetchone()["v"]
            delivered_total = stats["total_delivered"]

            cur.execute("""SELECT COALESCE(SUM(quantity_produced - quantity_assembled),0) AS v
                           FROM materials WHERE quantity_produced > quantity_assembled""")
            stats["pending_assembly"] = cur.fetchone()["v"]

            cur.execute("""SELECT COALESCE(SUM(quantity_assembled - quantity_delivered),0) AS v
                           FROM materials WHERE quantity_assembled > quantity_delivered""")
            stats["pending_delivery"] = cur.fetchone()["v"]

            cur.execute("SELECT COUNT(*) AS v FROM materials")
            stats["material_types"] = cur.fetchone()["v"]

            cur.execute("""SELECT COALESCE(SUM(quantity_produced),0) AS v FROM production_log
                           WHERE log_date = CURDATE()""")
            stats["daily_production"] = cur.fetchone()["v"]

            cur.execute("""SELECT COALESCE(SUM(quantity_produced),0) AS v FROM production_log
                           WHERE MONTH(log_date) = MONTH(CURDATE()) AND YEAR(log_date) = YEAR(CURDATE())""")
            stats["monthly_production"] = cur.fetchone()["v"]

            cur.execute("""SELECT log_date, SUM(quantity_produced) AS v FROM production_log
                           WHERE log_date >= CURDATE() - INTERVAL 6 DAY
                           GROUP BY log_date ORDER BY log_date ASC""")
            for r in cur.fetchall():
                trend_labels.append(r["log_date"].strftime("%d %b"))
                trend_values.append(r["v"])
        conn.close()
    except Exception:
        # Dashboard still renders with zeros if DB isn't reachable yet (matches
        # the "fresh install, empty DB" screenshot state)
        pass

    return render_template(
        "dashboard.html",
        user=session.get("user"),
        stats=stats,
        year=datetime.date.today().year,
        trend_labels=trend_labels,
        trend_values=trend_values,
        assembled_total=assembled_total,
        delivered_total=delivered_total,
    )


@app.route("/materials")
@login_required
def materials():
    return render_template("placeholder.html", user=session.get("user"), page="Materials")


@app.route("/production-tracking")
@login_required
def production_tracking():
    return render_template("placeholder.html", user=session.get("user"), page="Production Tracking")


@app.route("/inventory")
@login_required
def inventory():
    return render_template("placeholder.html", user=session.get("user"), page="Inventory")


@app.route("/reports")
@login_required
def reports():
    return render_template("placeholder.html", user=session.get("user"), page="Reports")


@app.route("/profile")
@login_required
def profile():
    return render_template("placeholder.html", user=session.get("user"), page="Profile")


# Prometheus metrics endpoint (basic - request count via prometheus_flask_exporter)
try:
    from prometheus_flask_exporter import PrometheusMetrics
    metrics = PrometheusMetrics(app)
except ImportError:
    pass


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)
