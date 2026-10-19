import importlib
import json
import threading
import urllib.error
import urllib.request

import pytest


def start(monkeypatch, tmp_path, mode):
    monkeypatch.setenv("MODE", mode)
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    import app
    importlib.reload(app)
    server = app.make_server(0)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return app, server, f"http://127.0.0.1:{server.server_address[1]}"


def call(url, data=None):
    req = urllib.request.Request(url, data=None if data is None else json.dumps(data).encode(), method="POST" if data is not None else "GET")
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as err:
        return err.code, json.loads(err.read())


@pytest.fixture
def stateful(monkeypatch, tmp_path):
    app, server, url = start(monkeypatch, tmp_path, "stateful")
    yield app, url, tmp_path
    server.shutdown()


@pytest.fixture
def stateless(monkeypatch, tmp_path):
    _, server, url = start(monkeypatch, tmp_path, "stateless")
    yield url
    server.shutdown()


def test_health_and_ready(stateful):
    _, url, _ = stateful
    assert call(url + "/healthz")[0] == 200 and call(url + "/readyz")[0] == 200


def test_notes_roundtrip(stateful):
    _, url, _ = stateful
    assert call(url + "/notes", {"text": "hello"})[0] == 201
    assert call(url + "/notes", {"text": "world"})[0] == 201
    status, body = call(url + "/notes")
    assert status == 200 and body["count"] == 2 and body["notes"][0]["text"] == "world"


@pytest.mark.parametrize("bad", [{}, {"text": ""}, {"text": "x" * 501}])
def test_rejects_bad_notes(stateful, bad):
    _, url, _ = stateful
    assert call(url + "/notes", bad)[0] == 400


def test_data_survives_restart(monkeypatch, tmp_path):
    _, server, url = start(monkeypatch, tmp_path, "stateful")
    call(url + "/notes", {"text": "keep me"})
    server.shutdown()
    _, server2, url2 = start(monkeypatch, tmp_path, "stateful")
    assert call(url2 + "/notes")[1]["count"] == 1
    server2.shutdown()


def test_checkpoint_flushes_wal_into_main_file(stateful):
    app, url, tmp = stateful
    call(url + "/notes", {"text": "a"})
    app.checkpoint()
    assert not (tmp / "notes.db-wal").exists() or (tmp / "notes.db-wal").stat().st_size == 0
    assert (tmp / "notes.db").stat().st_size > 0


def test_not_ready_when_data_dir_unusable(stateful):
    app, url, tmp = stateful
    import os
    import shutil
    shutil.rmtree(tmp)
    open(tmp, "w").close()  # a file where the directory should be
    try:
        assert call(url + "/readyz")[0] == 503
    finally:
        os.remove(tmp)
        os.makedirs(tmp)


def test_stateless_mode(stateless):
    assert call(stateless + "/work")[0] == 200
    assert call(stateless + "/notes")[0] == 404  # no data endpoints in stateless mode
    assert call(stateless + "/info")[1]["mode"] == "stateless"
