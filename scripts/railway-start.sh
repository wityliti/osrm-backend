#!/bin/sh
# Railway startup: use existing OSRM data or download and process a small region, then run osrm-routed.
set -e

DATA_DIR="${OSRM_DATA_DIR:-/data}"
PROFILE="${OSRM_PROFILE:-car}"
OSM_URL="${OSRM_OSM_URL:-https://download.geofabrik.de/europe/monaco-latest.osm.pbf}"
OSM_URL_FALLBACK="${OSRM_OSM_URL_FALLBACK:-}"
REGION_NAME="${OSRM_REGION_NAME:-region}"

fail () {
  echo "Failed: $1"
  echo "Waiting 30s before exit so logs are visible..."
  sleep 30
  exit 1
}

prepare_data () {
  echo "No OSRM data in $DATA_DIR. Preparing (profile=$PROFILE, url=$OSM_URL)..."
  if ! [ -d "$DATA_DIR" ]; then
    mkdir -p "$DATA_DIR" || fail "cannot create $DATA_DIR"
  fi
  if ! [ -w "$DATA_DIR" ]; then
    fail "directory $DATA_DIR is not writable. Set RAILWAY_RUN_UID=0 in Variables."
  fi
  cd "$DATA_DIR" || fail "cannot cd to $DATA_DIR"
  echo "Step 1/4: Downloading OSM extract..."
  
  # S3 bucket download function (for Railway Storage Buckets)
  download_from_s3 () {
    local url="$1"
    local bucket_name=""
    local object_key=""
    
    # Extract bucket and key from various URL formats
    # Format: https://<bucket>.storage.railway.app/<key>
    if echo "$url" | grep -q 'storage\.railway\.app'; then
      bucket_name=$(echo "$url" | sed -n 's|https://\([^.]*\)\.storage\.railway\.app.*|\1|p')
      object_key=$(echo "$url" | sed -n 's|https://[^/]*/\(.*\)|\1|p')
    fi
    
    if [ -z "$bucket_name" ] || [ -z "$object_key" ]; then
      echo "Could not parse S3 bucket URL: $url"
      return 1
    fi
    
    echo "Downloading from S3 bucket: $bucket_name, key: $object_key"
    
    # Use aws CLI if available
    if command -v aws >/dev/null 2>&1; then
      AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-$ACCESS_KEY_ID}" \
      AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-$SECRET_ACCESS_KEY}" \
      AWS_REGION="${AWS_REGION:-${REGION:-auto}}" \
      aws s3 cp "s3://${bucket_name}/${object_key}" "${REGION_NAME}.osm.pbf" \
        --endpoint-url "https://storage.railway.app"
    else
      # Fallback: generate presigned-like request using curl with AWS Signature
      echo "aws CLI not available, trying direct S3 request..."
      # For Railway buckets, we need to use virtual-hosted style
      curl -sLf --retry 2 --retry-delay 5 --retry-max-time 60 \
        --connect-timeout 30 --max-time 600 \
        -H "Authorization: AWS4-HMAC-SHA256 ..." \
        -o "${REGION_NAME}.osm.pbf" "$url"
    fi
  }
  
  download_osm () {
    local url="$1"
    
    # Check if this is a Railway bucket URL and we have S3 credentials
    if echo "$url" | grep -q 'storage\.railway\.app' && [ -n "${AWS_ACCESS_KEY_ID:-$ACCESS_KEY_ID}" ]; then
      echo "Detected Railway bucket URL, using S3 authentication..."
      download_from_s3 "$url"
    else
      # Standard HTTP download for public URLs (e.g., Geofabrik)
      curl -sLf --retry 2 --retry-delay 5 --retry-max-time 60 \
        -A "OSRM-Railway/1.0 (https://github.com/Project-OSRM/osrm-backend)" \
        --connect-timeout 30 --max-time 600 \
        -o "${REGION_NAME}.osm.pbf" "$url"
    fi
  }
  if ! download_osm "$OSM_URL"; then
    if [ -n "$OSM_URL_FALLBACK" ]; then
      echo "Primary URL failed, trying fallback: $OSM_URL_FALLBACK"
      if ! download_osm "$OSM_URL_FALLBACK"; then
        try_baked_in
      fi
    else
      try_baked_in
    fi
  fi
  if ! [ -f "${REGION_NAME}.osm.pbf" ]; then
    CODE=$(curl -sL -o /dev/null -w '%{http_code}' --connect-timeout 10 -A "OSRM-Railway/1.0" "$OSM_URL" 2>/dev/null || echo "unknown")
    fail "curl download failed for $OSM_URL (HTTP $CODE). No fallback. Set OSRM_OSM_URL_FALLBACK or check network egress."
  fi
  echo "Step 2/4: Running osrm-extract (this may take a few minutes)..."
  if ! /usr/local/bin/osrm-extract -p "/opt/${PROFILE}.lua" "${REGION_NAME}.osm.pbf"; then
    fail "osrm-extract failed (check logs above)"
  fi
  echo "Step 3/4: Running osrm-partition..."
  if ! /usr/local/bin/osrm-partition "${REGION_NAME}.osrm"; then
    fail "osrm-partition failed (check logs above)"
  fi
  echo "Step 4/4: Running osrm-customize..."
  if ! /usr/local/bin/osrm-customize "${REGION_NAME}.osrm"; then
    fail "osrm-customize failed (check logs above)"
  fi
  echo "Data ready. Starting routing engine."
}

try_baked_in () {
  if [ -f /opt/default-region.osm.pbf ]; then
    echo "Using baked-in Monaco extract (runtime download failed - network egress may be blocked)."
    cp /opt/default-region.osm.pbf "${REGION_NAME}.osm.pbf"
  else
    CODE=$(curl -sL -o /dev/null -w '%{http_code}' --connect-timeout 10 -A "OSRM-Railway/1.0" "$OSM_URL" 2>/dev/null || echo "unknown")
    fail "curl download failed for $OSM_URL (HTTP $CODE). Set OSRM_OSM_URL_FALLBACK to a URL you control (e.g. bucket) or check network egress."
  fi
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
