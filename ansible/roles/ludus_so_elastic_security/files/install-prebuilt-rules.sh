#!/bin/bash
# Install security_detection_engine, then the Elastic prebuilt rules.
# One ALL_RULES post installs every rule in a single Kibana request. On a
# standalone manager that request gets an empty reply (curl 52) right after
# the Fleet package install. Install the review page in chunks instead, and
# retry when Kibana drops the connection.
set -euo pipefail

CFG="${LUDUS_SO_CURL_CONFIG:-/opt/so/conf/elasticsearch/curl.config}"
POL="${LUDUS_SO_AGENT_POLICY:-endpoints-initial}"
PKG="${LUDUS_SO_DETECTION_PACKAGE:-security_detection_engine}"
VER="${LUDUS_SO_DETECTION_VERSION:-}"
CHUNK="${LUDUS_SO_RULE_CHUNK:-100}"
WAIT="${LUDUS_SO_KIBANA_WAIT:-600}"
RETRY_SLEEP="${LUDUS_SO_RETRY_SLEEP:-5}"
BASE="${LUDUS_SO_KIBANA_URL:-}"

if (( CHUNK < 1 || CHUNK > 500 )); then
  echo "LUDUS_SO_RULE_CHUNK must be 1-500" >&2
  exit 1
fi

ERR=$(mktemp)
trap 'rm -f "$ERR"' EXIT

fleet_headers=(-H 'kbn-xsrf: true' -H 'Content-Type: application/json')
internal_headers=(
  -H 'kbn-xsrf: true'
  -H 'Content-Type: application/json'
  -H 'elastic-api-version: 1'
  -H 'x-elastic-internal-origin: Kibana'
)

wait_kibana() {
  local limit="$1"
  local deadline=$((SECONDS + limit))
  local -a candidates=()
  local candidate
  if [[ -n "${LUDUS_SO_KIBANA_URL:-}" ]]; then
    candidates=("$LUDUS_SO_KIBANA_URL")
  else
    candidates=("https://127.0.0.1:5601" "http://127.0.0.1:5601")
  fi
  while (( SECONDS <= deadline )); do
    for candidate in "${candidates[@]}"; do
      if curl -skf --max-time 8 -K "$CFG" "${candidate}/api/status" >/dev/null 2>>"$ERR"; then
        BASE="${candidate}"
        return 0
      fi
    done
    if (( SECONDS >= deadline )); then
      break
    fi
    sleep "$RETRY_SLEEP"
  done
  echo "Kibana did not answer /api/status" >&2
  return 1
}

# Print the response body. Retry when Kibana accepts the socket and sends nothing.
kbn() {
  local kind="$1"
  local method="$2"
  local url="$3"
  local data="${4:-}"
  local -a headers=()
  local attempt raw code resp rc
  if [[ "$kind" == "internal" ]]; then
    headers=("${internal_headers[@]}")
  else
    headers=("${fleet_headers[@]}")
  fi
  for attempt in $(seq 1 12); do
    set +e
    if [[ -n "$data" ]]; then
      raw=$(curl -skS --max-time 180 -K "$CFG" "${headers[@]}" \
        -X "$method" "$url" --data-binary "$data" -w '\n%{http_code}' 2>"$ERR")
    else
      raw=$(curl -skS --max-time 120 -K "$CFG" "${headers[@]}" \
        -X "$method" "$url" -w '\n%{http_code}' 2>"$ERR")
    fi
    rc=$?
    set -e
    if [[ "$rc" -eq 0 ]]; then
      code=$(tail -n1 <<<"$raw")
      resp=$(sed '$d' <<<"$raw")
      if [[ "$code" == "200" || "$code" == "201" ]]; then
        printf '%s' "$resp"
        return 0
      fi
      if [[ "$code" != "502" && "$code" != "503" && "$code" != "000" ]]; then
        echo "kibana ${method} ${url} failed (http ${code}): $(printf '%s' "$resp" | head -c 500)" >&2
        return 1
      fi
      echo "kibana ${method} ${url} http ${code}; retry ${attempt}" >&2
    else
      if [[ "$rc" -ne 7 && "$rc" -ne 52 && "$rc" -ne 56 && "$rc" -ne 28 ]]; then
        cat "$ERR" >&2
        return "$rc"
      fi
      echo "kibana ${method} ${url} dropped the connection (curl ${rc}); retry ${attempt}" >&2
    fi
    wait_kibana 90 || true
  done
  echo "kibana ${method} ${url} still failing" >&2
  return 1
}

wait_kibana "$WAIT"

LIST=$(kbn fleet GET "${BASE}/api/fleet/package_policies?perPage=200")
if ! jq -e '.items' >/dev/null <<<"$LIST"; then
  echo "package policy list failed: $(printf '%s' "$LIST" | head -c 400)" >&2
  exit 1
fi
existing=$(jq -r --arg pkg "$PKG" '
  [.items[]? | select(.package.name == $pkg)]
  | .[0]
  | if . == null then "" else "\(.id) \(.name) \(.package.version)" end
' <<<"$LIST")
if [[ -n "$existing" ]]; then
  echo "already_installed ${existing}"
else
  if [[ -z "$VER" ]]; then
    info=$(kbn fleet GET "${BASE}/api/fleet/epm/packages/${PKG}")
    VER=$(jq -r '.item.latestVersion // .item.version // .version // empty' <<<"$info")
  fi
  if [[ -z "$VER" || "$VER" == "null" ]]; then
    echo "could not resolve ${PKG} version: $(printf '%s' "${info:-}" | head -c 400)" >&2
    exit 1
  fi
  name="${PKG}-1"
  body=$(jq -nc --arg ver "$VER" --arg pol "$POL" --arg name "$name" --arg pkg "$PKG" '{
    policy_ids: [$pol],
    package: {name: $pkg, version: $ver},
    name: $name,
    description: "",
    namespace: "",
    inputs: {}
  }')
  resp=$(kbn fleet POST "${BASE}/api/fleet/package_policies" "$body")
  echo "installed $(jq -r '"\(.item.id) \(.item.name) \(.item.package.version)"' <<<"$resp")"
fi

# The package install can restart Kibana. The next call has to wait for it.
wait_kibana 120

installed_n=0
failed_n=0
previous_ids=""
guard=0
while (( guard < 40 )); do
  guard=$((guard + 1))
  review=$(kbn internal POST "${BASE}/internal/detection_engine/prebuilt_rules/installation/_review" \
    "{\"page\":1,\"per_page\":${CHUNK}}")
  if ! jq -e '.total | type == "number"' >/dev/null <<<"$review"; then
    echo "prebuilt review failed: $(printf '%s' "$review" | head -c 400)" >&2
    exit 1
  fi
  total=$(jq -r '.total' <<<"$review")
  if [[ "$total" == "0" ]]; then
    break
  fi
  ids=$(jq -c '[.rules[]?.rule_id] | sort' <<<"$review")
  if [[ "$ids" == "$previous_ids" ]]; then
    echo "prebuilt install made no progress: $(printf '%s' "$ids" | head -c 300)" >&2
    exit 1
  fi
  previous_ids="$ids"
  chunk=$(jq -c '[.rules[]? | select(.rule_id != null and (.version | type == "number")) | {rule_id, version}]' <<<"$review")
  count=$(jq -r 'length' <<<"$chunk")
  if [[ "$count" == "0" ]]; then
    echo "prebuilt review listed ${total} rules but none had rule_id and version" >&2
    exit 1
  fi
  body=$(jq -nc --argjson rules "$chunk" '{mode:"SPECIFIC_RULES", rules:$rules}')
  resp=$(kbn internal POST "${BASE}/internal/detection_engine/prebuilt_rules/installation/_perform" "$body")
  if ! jq -e '.summary.succeeded | type == "number"' >/dev/null <<<"$resp"; then
    echo "install response missing summary: $(printf '%s' "$resp" | head -c 400)" >&2
    exit 1
  fi
  succeeded=$(jq -r '.summary.succeeded' <<<"$resp")
  failed=$(jq -r '.summary.failed' <<<"$resp")
  installed_n=$((installed_n + succeeded))
  failed_n=$((failed_n + failed))
  echo "chunk rules=${count} succeeded=${succeeded} failed=${failed}"
  if [[ "$failed" != "0" ]]; then
    echo "prebuilt install failed for ${failed} rules: $(jq -c '.errors[:1]' <<<"$resp" | head -c 400)" >&2
    exit 1
  fi
done

if (( guard >= 40 )) && [[ "${total:-1}" != "0" ]]; then
  echo "prebuilt install did not finish" >&2
  exit 1
fi

echo "prebuilt_installed=${installed_n} prebuilt_failed=${failed_n}"

status=$(kbn internal GET "${BASE}/internal/detection_engine/prebuilt_rules/status")
if ! jq -e '.stats.num_prebuilt_rules_to_install | type == "number"' >/dev/null <<<"$status"; then
  echo "prebuilt status failed: $(printf '%s' "$status" | head -c 400)" >&2
  exit 1
fi
echo "prebuilt_status $(jq -c .stats <<<"$status")"
left=$(jq -r '.stats.num_prebuilt_rules_to_install' <<<"$status")
if [[ "$left" != "0" ]]; then
  echo "${left} Elastic rules are still not installed" >&2
  exit 1
fi
