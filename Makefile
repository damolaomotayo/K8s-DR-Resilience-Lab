.PHONY: test up drills destroy
test:    ; .venv/bin/python -m pytest -q
up:      ; scripts/up.sh
drills:  ; scripts/run-all.sh
destroy: ; scripts/destroy.sh
