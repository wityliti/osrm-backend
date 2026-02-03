#!/bin/sh
# Railway startup: use existing OSRM data or download and process a small region, then run osrm-routed.
set -e

DATA_DIR="${OSRM_DATA_DIR:-/data}"
PROFILE="${OSRM_PROFILE:-car}"
OSM_URL="${OSRM_OSM_URL:-https://download.geofabrik.de/europe/monaco-latest.osm.pbf}"
REGION_NAME="${OSRM_REGION_NAME:-region}"

prepare_data () {
  echo "No OSRM data in $DATA_DIR. Downloading OSM extract and processing (profile=$PROFILE)..."
  cd "$DATA_DIR"
  curl -sL -o "${REGION_NAME}.osm.pbf" "$OSM_URL"
  /usr/local/bin/osrm-extract -p "/opt/${PROFILE}.lua" "${REGION_NAME}.osm.pbf"
  /usr/local/bin/osrm-partition "${REGION_NAME}.osrm"
  /usr/local/bin/osrm-customize "${REGION_NAME}.osrm"
  echo "Data ready. Starting routing engine."
}

# Find existing .osrm base (file named exactly *.osrm, not *.osrm.xxx)
BASE_PATH=""
for f in "${DATA_DIR}"/*.osrm; do
  [ -f "$f" ] && [ "${f%.osrm}" != "$f" ] && BASE_PATH="${f%.osrm}" && break
done

if [ -z "$BASE_PATH" ]; then
  prepare_data
  BASE_PATH="${DATA_DIR}/${REGION_NAME}"
else
  # Volume may have partial/corrupt data from a previous failed run - verify it loads
  if ! /usr/local/bin/osrm-routed --algorithm mld --trial "${BASE_PATH}.osrm" 2>/dev/null; then
    echo "Existing OSRM data invalid or incomplete. Re-preparing..."
    rm -f "${DATA_DIR}"/*.osrm "${DATA_DIR}"/*.osrm.* "${DATA_DIR}"/*.osm.pbf 2>/dev/null || true
    prepare_data
    BASE_PATH="${DATA_DIR}/${REGION_NAME}"
  fi
fi

# Railway sets PORT; osrm-routed defaults to 5000 and binds to 0.0.0.0
LISTEN_PORT="${PORT:-5000}"
exec /usr/local/bin/osrm-routed --algorithm mld --port "$LISTEN_PORT" "${BASE_PATH}.osrm"
