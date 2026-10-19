"""Policy-as-tests: every workload in k8s/ must meet the lab's resilience and security rules."""
import glob
import os

import pytest
import yaml

ROOT = os.path.join(os.path.dirname(__file__), "..", "k8s")


def load():
    docs = []
    for path in sorted(glob.glob(os.path.join(ROOT, "*.yaml"))):
        docs += [d for d in yaml.safe_load_all(open(path)) if d]
    return docs


DOCS = load()
WORKLOADS = [d for d in DOCS if d["kind"] in ("Deployment", "StatefulSet")]


def pod_spec(w):
    return w["spec"]["template"]["spec"]


def name(w):
    return f"{w['kind']}/{w['metadata']['name']}"


def test_there_are_workloads():
    assert {w["metadata"]["name"] for w in WORKLOADS} == {"web", "notes"}


@pytest.mark.parametrize("w", WORKLOADS, ids=name)
def test_pod_runs_non_root_with_seccomp(w):
    sc = pod_spec(w)["securityContext"]
    assert sc["runAsNonRoot"] is True and sc["seccompProfile"]["type"] == "RuntimeDefault"


@pytest.mark.parametrize("w", WORKLOADS, ids=name)
def test_containers_hardened_and_bounded(w):
    for c in pod_spec(w)["containers"]:
        sc = c["securityContext"]
        assert sc["allowPrivilegeEscalation"] is False and sc["readOnlyRootFilesystem"] is True
        assert sc["capabilities"]["drop"] == ["ALL"]
        for kind in ("requests", "limits"):
            assert {"cpu", "memory"} <= set(c["resources"][kind])


@pytest.mark.parametrize("w", WORKLOADS, ids=name)
def test_probes_present(w):
    for c in pod_spec(w)["containers"]:
        assert {"livenessProbe", "readinessProbe", "startupProbe"} <= set(c)


@pytest.mark.parametrize("w", WORKLOADS, ids=name)
def test_image_is_pinned(w):
    for c in pod_spec(w)["containers"]:
        assert ":" in c["image"] and not c["image"].endswith(":latest")


@pytest.mark.parametrize("w", WORKLOADS, ids=name)
def test_selector_matches_template_labels(w):
    labels = w["spec"]["template"]["metadata"]["labels"]
    assert all(labels.get(k) == v for k, v in w["spec"]["selector"]["matchLabels"].items())


def test_replicated_deployments_have_pdb_and_spread():
    pdbs = [d for d in DOCS if d["kind"] == "PodDisruptionBudget"]
    for w in WORKLOADS:
        if w["kind"] == "Deployment" and w["spec"]["replicas"] > 1:
            labels = w["spec"]["template"]["metadata"]["labels"]
            matching = [p for p in pdbs if all(labels.get(k) == v for k, v in p["spec"]["selector"]["matchLabels"].items())]
            assert matching, f"{name(w)} has no PodDisruptionBudget"
            assert matching[0]["spec"]["minAvailable"] < w["spec"]["replicas"], "PDB would block every drain"
            assert pod_spec(w).get("topologySpreadConstraints"), f"{name(w)} is not spread across nodes"
            assert w["spec"]["strategy"]["rollingUpdate"]["maxUnavailable"] == 0


def test_stateful_workload_is_backed_up_consistently():
    sts = next(w for w in WORKLOADS if w["kind"] == "StatefulSet")
    ann = sts["spec"]["template"]["metadata"]["annotations"]
    claims = {c["metadata"]["name"] for c in sts["spec"]["volumeClaimTemplates"]}
    assert set(ann["backup.velero.io/backup-volumes"].split(",")) <= claims
    assert "pre.hook.backup.velero.io/command" in ann and ann["pre.hook.backup.velero.io/on-error"] == "Fail"


def test_ingress_backends_exist():
    services = {d["metadata"]["name"]: d for d in DOCS if d["kind"] == "Service"}
    for ing in (d for d in DOCS if d["kind"] == "Ingress"):
        for rule in ing["spec"]["rules"]:
            for p in rule["http"]["paths"]:
                assert p["backend"]["service"]["name"] in services


def test_everything_lives_in_the_lab_namespace():
    for d in DOCS:
        if d["kind"] != "Namespace":
            assert d["metadata"]["namespace"] == "drlab", name(d) if d["kind"] in ("Deployment", "StatefulSet") else d["kind"]
