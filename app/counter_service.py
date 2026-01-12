import os
import json
import logging
import threading
from pathlib import Path
from flask import Flask, request

# Linux file locking (EKS nodes are Linux)
import fcntl
from contextlib import contextmanager


LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()
logging.basicConfig(level=LOG_LEVEL, format="%(message)s")
logger = logging.getLogger("counter-service")

COUNTER_FILE = os.getenv("COUNTER_FILE", "/data/counter.json")
APP_VERSION = os.getenv("APP_VERSION", "dev")

app = Flask(__name__)

def log_json(level_func, payload: dict) -> None:
    payload = {
        **payload,
        "pid": os.getpid(),
        "tid": threading.get_ident(),
    }
    level_func(json.dumps(payload, ensure_ascii=False))

def _read_counter(path: Path) -> int:
    if not path.exists():
        return 0

    try:
        with path.open("r", encoding="utf-8") as file:
            data = json.load(file)
            return int(data.get("counter", 0))
    except Exception as e:
        log_json(logger.warning, {"event": "read_failed", "path": str(path), "error": str(e)})
        return 0

def _write_counter(path: Path, value: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)

    tmp_path = path.with_suffix(".tmp")
    with tmp_path.open("w", encoding="utf-8") as file:
        json.dump({"counter": value}, file)
    tmp_path.replace(path)

@contextmanager
def _exclusive_file_lock(target_path: Path):
    lock_path = target_path.with_suffix(".lock")
    lock_path.parent.mkdir(parents=True, exist_ok=True)

    lock_f = lock_path.open("w")
    try:
        fcntl.flock(lock_f, fcntl.LOCK_EX)
        yield
    finally:
        try:
            fcntl.flock(lock_f, fcntl.LOCK_UN)
        finally:
            lock_f.close()

@app.get("/healthz")
def healthz():
    return {"status": "ok"}, 200

@app.get("/version")
def version():
    return {"version": APP_VERSION}, 200

@app.route("/", methods=["POST", "GET"])
def index():
    path = Path(COUNTER_FILE)

    if request.method == "POST":
        with _exclusive_file_lock(path):
            current = _read_counter(path)
            current += 1
            _write_counter(path, current)

        log_json(logger.info, {"event": "increment", "counter": current})
        return {"counter": current}, 200

    current = _read_counter(path)
    return {"counter": current}, 200
