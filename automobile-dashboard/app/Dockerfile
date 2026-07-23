FROM python:3.12-slim

WORKDIR /app

# System deps needed for PyMySQL/bcrypt wheels build (kept minimal)
RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc default-libmysqlclient-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Run as non-root
RUN useradd -m appuser
USER appuser

EXPOSE 5000

# gunicorn: 3 workers is a sane default for a t3.small / small pod
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "3", "--access-logfile", "-", "--error-logfile", "-", "app:app"]
