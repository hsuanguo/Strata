FROM nvidia/cuda:13.0.1-devel-ubuntu24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

ENV VIRTUAL_ENV=/opt/venv \
    PATH="/opt/venv/bin:${PATH}" \
    PYTHONUNBUFFERED=1

WORKDIR /app
RUN python3 -m venv "$VIRTUAL_ENV"
COPY setup.py /app/setup.py
RUN python -c 'import setup, subprocess, sys; subprocess.check_call([sys.executable, "-m", "pip", "install", "--no-cache-dir", *setup.PY_PACKAGES, *setup.CUDA_WHEELS])' \
    && python -c 'import json, setup, sys; from pathlib import Path; (Path(sys.prefix) / ".strata-pip.json").write_text(json.dumps(sorted(set(setup.PY_PACKAGES + setup.CUDA_WHEELS))))'

COPY . /app
RUN chmod +x /app/docker-entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/app/docker-entrypoint.sh"]
