def test_counter_flow(tmp_path, monkeypatch):
    counter_file = tmp_path / "counter.json"
    monkeypatch.setenv("COUNTER_FILE", str(counter_file))
    monkeypatch.setenv("APP_VERSION", "test")

    import importlib
    appmod = importlib.import_module("counter_service")
    client = appmod.app.test_client()

    # GET initially should be 0
    r = client.get("/")
    assert r.status_code == 200
    assert r.json["counter"] == 0

    # POST increments
    r = client.post("/")
    assert r.status_code == 200
    assert r.json["counter"] == 1

    # GET should be 1
    r = client.get("/")
    assert r.status_code == 200
    assert r.json["counter"] == 1

    # version endpoint
    r = client.get("/version")
    assert r.status_code == 200
    assert r.json["version"] == "test"

    # health
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json["status"] == "ok"
