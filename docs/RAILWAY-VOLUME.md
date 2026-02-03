# Railway: Volume and storage for osrm-backend

## Volume (persistent disk) – recommended

**Use a volume for OSRM data** so that processed `.osrm` files persist across deploys and restarts.

- **What it does:** Gives the service persistent disk at a path (e.g. `/data`). No re-download or re-processing after the first successful run.
- **What it does not do:** It does **not** increase RAM. Memory is set per service by Railway.

### How to attach a volume

1. In Railway: open your project → select the **osrm-backend** service.
2. Go to **Settings** (or the service’s configuration).
3. Under **Volumes**, click **Add Volume** (or **+ New Volume**).
4. Set the **mount path** to: **`/data`**
5. Save. Redeploy the service so the volume is mounted at `/data`.

The startup script uses `OSRM_DATA_DIR=/data` by default, so data will be stored on this volume.

### Limits (Railway)

- One volume per service.
- Size depends on plan (e.g. Hobby ~5GB, Pro more).
- Do **not** mount the volume at `/app` (that can break the app).

---

## Bucket (object storage)

Railway **buckets** are S3-compatible object storage. They are **not** a filesystem you can mount.

- You can’t mount a bucket as `/data` for OSRM.
- You could use a bucket to **store** pre-processed `.osrm` files and change the app to **download** them at startup instead of running extract/partition/customize; that would require custom scripting and is not set up by default.

So for normal operation, use a **volume** at `/data`, not a bucket.

---

## Memory (RAM) and crashes

If the service **crashes during** “Downloading OSM extract and processing”, it is often due to **running out of memory (RAM)** during `osrm-extract` / `osrm-partition` / `osrm-customize`, not lack of disk.

- **Volume** = more **storage** (disk). Good for keeping `.osrm` data; does not increase RAM.
- **RAM** = set by Railway for the service (plan/instance size). To reduce OOM risk you can:
  - Use a **smaller OSM extract** (e.g. a city instead of a whole state), or
  - Use a Railway plan/configuration that gives the service **more memory**, if available.

So: attach a **volume** at **`/data`** for storage; if it still crashes during processing, address **memory** (smaller region or higher plan), not volume/bucket.

---

## If it keeps crashing after a failed run

If the service crashed during "Downloading OSM extract and processing", the volume may contain **partial or corrupt** data (e.g. only `.osm.pbf` or incomplete `.osrm` files). The next start might then try to use that and fail again.

**Fix:** In Railway, remove the volume from the osrm-backend service (or create a new volume and attach it at `/data`), then redeploy. The service will start with an empty `/data` and run the pipeline again. Use a **small** `OSRM_OSM_URL` (e.g. Monaco) so processing fits in memory.
