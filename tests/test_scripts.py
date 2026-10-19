import os
import re
import subprocess

ROOT = os.path.join(os.path.dirname(__file__), "..")
SCRIPTS = sorted(f for f in os.listdir(os.path.join(ROOT, "scripts")) if f.endswith(".sh"))


def test_scripts_exist():
    assert {"setup.sh", "up.sh", "destroy.sh", "run-all.sh", "drill-dr.sh"} <= set(SCRIPTS)


def test_scripts_parse_and_are_executable():
    for name in SCRIPTS:
        path = os.path.join(ROOT, "scripts", name)
        assert os.access(path, os.X_OK), f"{name} is not executable"
        assert open(path).readline().startswith("#!/usr/bin/env bash"), name
        subprocess.run(["bash", "-n", path], check=True)


def test_drill_scripts_use_shared_helpers():
    for name in SCRIPTS:
        if name.startswith("drill-"):
            assert 'source "$(dirname "$0")/lib.sh"' in open(os.path.join(ROOT, "scripts", name)).read(), name


def test_images_are_pinned_in_lib():
    lib = open(os.path.join(ROOT, "scripts", "lib.sh")).read()
    for var in ("K3S_IMAGE", "MINIO_IMAGE", "MC_IMAGE", "VELERO_AWS_PLUGIN"):
        match = re.search(rf'{var}="\$\{{{var}:-([^}}]+)\}}"', lib)
        assert match and ":" in match.group(1) and not match.group(1).endswith(":latest"), var


def test_recovery_cluster_cannot_write_backups():
    assert "ReadOnly" in open(os.path.join(ROOT, "scripts", "up.sh")).read()
