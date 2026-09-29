#!/usr/bin/env bash
# docker-entrypoint.sh - first-run setup via setup.py, then start serve.server.
#
# The launcher runs inside the image and writes / persists everything under /data so
# the model, engine, llama.cpp and generated config survive container removal.
#
# First launch: setup.py --yes is run with the STRATA_* env vars below, and every
# artifact it produces is moved into /data/. STRATA_RECONFIGURE=1 (or a marker file
# /data/.reconfigure) forces setup to run again on a later launch with new choices.
#
# See README.md "Docker (Linux)" for the supported env vars and how to pick a
# different model, context size, KV cache precision, vision support, GPU, or API
# settings on a later run.

set -euo pipefail

# ------------------------------------------------------------------------------------- defaults
: "${STRATA_FAMILY:=qwen}"        # qwen | swift | coder
: "${STRATA_MODEL:=IQ2_XS}"       # Q2_0 | IQ2_XS | IQ3_XXS | IQ3_S | IQ1_M
: "${STRATA_CONTEXT:=}"           # 8192 | 32768 | 65536 | 131072 | 262144 (blank = auto)
: "${STRATA_VISION:=no}"          # no | yes | gpu | cpu
: "${STRATA_KV:=}"                # int8 | q4_0 (blank = auto)
: "${STRATA_GPU:=0}"              # nvidia-smi number, "0,2" for a layer split
: "${STRATA_HOST:=0.0.0.0}"
: "${STRATA_PORT:=8080}"
: "${STRATA_API_KEY:=}"           # required from the API; set on the docker run command
: "${STRATA_RECONFIGURE:=}"       # set to 1 (or touch /data/.reconfigure) to re-run setup

# ------------------------------------------------------------------------------------- validate
die() { echo "strata-docker: $*" >&2; exit 2; }
case "${STRATA_VISION}" in yes|gpu|cpu|no|none) ;; *) die "STRATA_VISION must be one of: no | yes | gpu | cpu" ;; esac

# A vision-enabled engine is a different prebuilt (or a recompile). If the cached engine
# doesn't include strata-vision we silently fall back to text-only, with a clear message,
# rather than crashing when the server tries to spawn the encoder.
if [[ "${STRATA_VISION}" != "no" && "${STRATA_VISION}" != "none" ]]; then
    mkdir -p /data/engine
    if [[ -d /data/engine && ! -x /data/engine/strata-vision ]]; then
        echo "[strata-docker] WARNING: cached engine has no strata-vision; falling back to STRATA_VISION=no" >&2
        echo "[strata-docker]   to enable images, rebuild with: docker build --build-arg STRATA_VISION=gpu ..." >&2
        STRATA_VISION="no"
    fi
fi
case "${STRATA_FAMILY}" in qwen|swift|coder) ;;      *) die "STRATA_FAMILY must be one of: qwen | swift | coder"    ;; esac
case "${STRATA_MODEL}" in
    Q2_0|IQ2_XS|IQ3_XXS)
        [[ "${STRATA_FAMILY}" == "coder" ]] && die "STRATA_MODEL ${STRATA_MODEL} is not in the coder family" ;;
    IQ3_S)
        [[ "${STRATA_FAMILY}" != "qwen" ]] && die "STRATA_MODEL IQ3_S is only available for the original (qwen)" ;;
    IQ1_M)
        [[ "${STRATA_FAMILY}" != "coder" ]] && die "STRATA_MODEL IQ1_M is only available for the coder" ;;
    *) die "STRATA_MODEL must be one of: Q2_0 | IQ2_XS | IQ3_XXS | IQ3_S | IQ1_M" ;;
esac

# ------------------------------------------------------------------------------------- persistence
# Persist the engine binary so a recompile is only paid for once across container recreations.
mkdir -p /data/engine
rm -rf /app/engine
ln -s /data/engine /app/engine
# llama.cpp is downloaded by setup.py each time it runs; keep the fetched source between
# runs only if the user explicitly opted in to /data/llama.cpp (rare; safe to ignore).
if [[ -d /data/llama.cpp ]]; then
    rm -rf /app/third_party/llama.cpp
    ln -s /data/llama.cpp /app/third_party/llama.cpp
fi

# Every config setup.py writes is named /app/strata-<tag>.json; mirror it under /data and
# leave /app free of any generated state between launches. The latest config wins.
mirror_app_to_data() {
    for f in /app/strata-*.json /app/strata-*.log /app/run-*.sh; do
        [[ -e "$f" ]] || continue
        mv "$f" /data/
    done
    if [[ ! -d /data/llama.cpp && -d /app/third_party/llama.cpp && -d /app/third_party/llama.cpp/gguf-py ]]; then
        mv /app/third_party/llama.cpp /data/llama.cpp
        ln -s /data/llama.cpp /app/third_party/llama.cpp
    fi
}

# ------------------------------------------------------------------------------------- bootstrap
reconfigure() {
    [[ -n "${STRATA_RECONFIGURE}" ]] && return 0
    [[ -f /data/.reconfigure ]]       && return 0
    return 1
}

run_setup() {
    local args=(--yes --no-start "--family=${STRATA_FAMILY}" "--model=${STRATA_MODEL}"
                "--vision=${STRATA_VISION}" --data-dir /data)
    [[ -n "${STRATA_CONTEXT}" ]] && args+=("--context=${STRATA_CONTEXT}")
    [[ -n "${STRATA_KV}" ]]      && args+=("--kv=${STRATA_KV}")
    python setup.py "${args[@]}"
    cat > /data/.install.json <<JSON
{"family": "${STRATA_FAMILY}", "model": "${STRATA_MODEL}",
 "context": "${STRATA_CONTEXT}", "vision": "${STRATA_VISION}",
 "kv": "${STRATA_KV}", "gpu": "${STRATA_GPU}"}
JSON
}

pick_config() {
    local latest
    latest=$(ls -1t /data/strata-*.json 2>/dev/null | head -n1 || true)
    echo "${latest}"
}

if ! config=$(pick_config) || [[ -z "${config}" ]] || reconfigure; then
    echo "[strata-docker] running setup.py for ${STRATA_FAMILY}/${STRATA_MODEL} (vision=${STRATA_VISION}) ..."
    run_setup
    mirror_app_to_data
    rm -f /data/.reconfigure
    config=$(pick_config)
    [[ -z "${config}" ]] && die "setup.py did not produce a config under /data/strata-*.json"
fi

python - <<PY
import json, os, pathlib
p = pathlib.Path("${config}")
cfg = json.loads(p.read_text(encoding="utf-8-sig"))
changed = False
if str(cfg.get("gpu", "")) != "${STRATA_GPU}":
    cfg["gpu"] = "${STRATA_GPU}"
    changed = True
host, port = os.environ.get("STRATA_HOST", "${STRATA_HOST}"), os.environ.get("STRATA_PORT", "${STRATA_PORT}")
if str(cfg.get("port", "")) != str(port):
    cfg["port"] = int(port); changed = True
if str(cfg.get("host", "")) != host:
    cfg["host"] = host; changed = True
if changed:
    p.write_text(json.dumps(cfg, indent=1), encoding="utf-8")
PY

echo "[strata-docker] config: ${config}"
install=$(cat /data/.install.json 2>/dev/null || echo '{}')
echo "[strata-docker] install: ${install}"
echo "[strata-docker] API key: $([[ -n "${STRATA_API_KEY}" ]] && echo set || echo 'not set (open)')"
echo "[strata-docker] listening on http://${STRATA_HOST}:${STRATA_PORT}"
echo "[strata-docker] re-run setup with new choices:"
echo "                 docker run ... -e STRATA_RECONFIGURE=1 ...   or   touch /data/.reconfigure"

# Persist STRATA_API_KEY into the config so the server keeps requiring it even if a
# future launch forgets to set the env var (host/port are passed as flags every run,
# so they don't need to be saved).
if [[ -n "${STRATA_API_KEY}" ]]; then
    python - <<PY
import json, pathlib
p = pathlib.Path("${config}")
cfg = json.loads(p.read_text(encoding="utf-8-sig"))
if "${STRATA_API_KEY}" and not cfg.get("api_key"):
    cfg["api_key"] = "${STRATA_API_KEY}"
    p.write_text(json.dumps(cfg, indent=1), encoding="utf-8")
PY
fi

# Show all the env-derived choices the launcher applied, so the user can verify at a glance.
echo "[strata-docker] applying: family=${STRATA_FAMILY} model=${STRATA_MODEL}" \
     "context=${STRATA_CONTEXT:-auto} vision=${STRATA_VISION}" \
     "kv=${STRATA_KV:-auto} gpu=${STRATA_GPU}" \
     "host=${STRATA_HOST} port=${STRATA_PORT}" \
     "reconfigure=${STRATA_RECONFIGURE:-no}" \
     "marker=$([ -f /data/.reconfigure ] && echo yes || echo no)"

exec python -m serve.server --engine strata --config "${config}" \
    --host "${STRATA_HOST}" --port "${STRATA_PORT}" --gpu "${STRATA_GPU}"