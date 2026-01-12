# syntax=docker/dockerfile:1

FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Create non-root user
RUN useradd -u 10001 -m appuser

WORKDIR /app

# 1) Copy only requirements first (better build cache)
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 2) Then copy application code and other files
COPY app/code/ .

# Writable directory for persistence (PVC will mount here)
RUN mkdir -p /data && chown -R appuser:appuser /data

USER appuser

EXPOSE 8080

CMD ["gunicorn", "counter_service:app", "--bind", "0.0.0.0:8080", "--workers", "1", "--threads", "4", "--timeout", "30"]
