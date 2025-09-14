#!/usr/bin/env bash
set -euo pipefail
NS="${NS:-fio-lab}"
OUT="${OUT:-./results}"
STAGE="${STAGE:-run}"
mkdir -p "${OUT}/${STAGE}"
collect_group() {
  local app="$1"
  mapfile -t PODS < <(kubectl -n "${NS}" get pods -l app="${app}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  for p in "${PODS[@]}"; do
    [ -n "${p}" ] || continue
    d="${OUT}/${STAGE}/${p}"
    mkdir -p "${d}"
    if kubectl -n "${NS}" exec "${p}" -- test -f /results/fio.json 2>/dev/null; then
      kubectl -n "${NS}" cp "${p}:/results/fio.json" "${d}/fio.json" >/dev/null || true
    else
      echo "[WARN] ${p} has no /results/fio.json yet"
    fi
  done
}
collect_group victim || true
collect_group victim2x || true
collect_group noisy || true
python3 "$(dirname "$0")/summarize_fio_json.py" "${OUT}/${STAGE}" > "${OUT}/${STAGE}.csv" || echo "[WARN] summarize failed"
echo "[OK] Results in ${OUT}/${STAGE} and ${OUT}/${STAGE}.csv"
