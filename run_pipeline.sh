#!/bin/bash

# Strict mode: exit on error, exit on unset variable, fail pipelines
set -euo pipefail

# --- Configuration ---
REPO_URL="https://github.com/SauersML/inv.git"
REPO_DIR="inv"
# The Docker image tag MUST match what's expected in nextflow.config
# (which constructs it using GOOGLE_PROJECT)
# Note the specific tag '-py' used in the corrected config for the Python-only image
IMAGE_NAME="aou-h1h2-assoc-py"
IMAGE_VERSION="latest"

# --- Helper Functions ---
log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $@"
}

check_variable() {
  local var_name="$1"
  if [[ -z "${!var_name-}" ]]; then # Check if variable is unset or empty
    log "ERROR: Environment variable ${var_name} is not set."
    log "Please ensure you are running this script in a properly configured AoU environment."
    exit 1
  fi
  log "INFO: ${var_name}=${!var_name}"
}

# --- Main Script ---

log "Starting AoU H1/H2 Association Pipeline Runner Script"

# 1. Check Essential Environment Variables
log "Step 1: Checking environment variables..."
check_variable "GOOGLE_PROJECT"
check_variable "WORKSPACE_CDR"
check_variable "WORKSPACE_BUCKET"
log "INFO: Environment variables checked successfully."

# 2. Clone or Update Repository
log "Step 2: Cloning or updating repository ${REPO_URL}..."
if [ -d "${REPO_DIR}" ]; then
  log "INFO: Directory ${REPO_DIR} already exists. Removing for fresh clone."
  rm -rf "${REPO_DIR}"
fi
git clone "${REPO_URL}" "${REPO_DIR}"
cd "${REPO_DIR}"
log "INFO: Successfully cloned repository and changed directory to ${REPO_DIR}."

# 3. Enable Required GCP APIs
log "Step 3: Enabling necessary GCP APIs..."
# List from README/knowledge of components
REQUIRED_APIS=(
  "compute.googleapis.com"
  "lifesciences.googleapis.com"
  "containerregistry.googleapis.com"
  "storage-component.googleapis.com" # GCS API
  "bigquery.googleapis.com"
  "dataproc.googleapis.com"
)
# Join array elements with commas
api_list=$(IFS=,; echo "${REQUIRED_APIS[*]}")
if gcloud services enable "${api_list}" --project="${GOOGLE_PROJECT}"; then
  log "INFO: Ensured necessary APIs are enabled."
else
  log "WARNING: Failed to enable some APIs. This might cause issues later if they weren't already enabled. Check permissions."
fi

# 4. Build Docker Image
log "Step 4: Building Docker image..."
IMAGE_TAG="gcr.io/${GOOGLE_PROJECT}/${IMAGE_NAME}:${IMAGE_VERSION}"
log "INFO: Building image with tag: ${IMAGE_TAG}"
# Dockerfile exists
if [ ! -f Dockerfile ]; then
    log "ERROR: Dockerfile not found in repository root (${PWD})."
    exit 1
fi
if docker build -t "${IMAGE_TAG}" .; then
  log "INFO: Docker image built successfully."
else
  log "ERROR: Docker image build failed."
  exit 1
fi

# 5. Configure Docker for GCR
log "Step 5: Configuring Docker authentication for GCR..."
# Use --quiet to reduce verbose output
if gcloud auth configure-docker --quiet; then
  log "INFO: Docker configured for GCR."
else
  log "ERROR: Failed to configure Docker for GCR. Check gcloud authentication."
  exit 1
fi

# 6. Push Docker Image to GCR
log "Step 6: Pushing Docker image to GCR..."
if docker push "${IMAGE_TAG}"; then
  log "INFO: Docker image pushed successfully to ${IMAGE_TAG}."
else
  log "ERROR: Failed to push Docker image. Check GCR permissions for project ${GOOGLE_PROJECT}."
  exit 1
fi

# 7. Prepare for Nextflow Run
log "Step 7: Preparing for Nextflow execution..."
# Define output directory with a timestamp
RUN_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="${WORKSPACE_BUCKET}/results/aou_h1h2_assoc_${RUN_TIMESTAMP}"
log "INFO: Pipeline output directory: ${OUTPUT_DIR}"
# Note: nextflow.config uses environment variables for CDR_ID and implicitly for GOOGLE_PROJECT (in container path).
# It REQUIRES output_dir_gcs parameter or env var derivation. We will pass it explicitly.

# Check if Nextflow command exists
if ! command -v nextflow &> /dev/null; then
    log "ERROR: 'nextflow' command not found. Please install Nextflow."
    exit 1
fi

# 8. Execute Nextflow Pipeline
log "Step 8: Executing Nextflow pipeline..."
log "INFO: Running command: nextflow run main.nf -profile google --output_dir_gcs \"${OUTPUT_DIR}\" -resume ..."

if nextflow run main.nf \
    -profile google \
    --output_dir_gcs "${OUTPUT_DIR}" \
    -with-report "${OUTPUT_DIR}/reports/nextflow_report.html" \
    -with-trace "${OUTPUT_DIR}/reports/nextflow_trace.txt" \
    -with-timeline "${OUTPUT_DIR}/reports/nextflow_timeline.html" \
    -resume; then
  log "SUCCESS: Nextflow pipeline completed successfully!"
  log "INFO: Outputs located in GCS: ${OUTPUT_DIR}"
  # Display final results path from completion log if possible (tricky from bash script)
else
  log "ERROR: Nextflow pipeline execution failed."
  log "INFO: Check the Nextflow logs and the output directory for details: ${OUTPUT_DIR}"
  # Check Dataproc logs in GCP console if failure seems related to Hail step
  exit 1 # script exits with non-zero status on failure
fi

log "Pipeline Runner Script Finished."
exit 0
