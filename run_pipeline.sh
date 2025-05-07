#!/bin/bash

# Strict mode: exit on error, exit on unset variable, fail pipelines
set -euo pipefail

# --- Configuration ---
GHCR_REGISTRY="ghcr.io"
GITHUB_OWNER="sauersml" # lowercase for Docker image path compatibility
IMAGE_BASE_NAME="aou-analysis-runner"
IMAGE_VERSION="latest"

TARGET_IMAGE="${GHCR_REGISTRY}/${GITHUB_OWNER}/${IMAGE_BASE_NAME}:${IMAGE_VERSION}"

# Command(s) to run inside the Docker container.
# This can be overridden by setting the AOC_COMMAND_IN_CONTAINER environment variable
# before running this script.
AOC_DEFAULT_COMMAND="echo '--- Running inside Docker container ---'; \
echo 'Date: $(date)'; \
echo 'User: $(whoami)'; \
echo 'Hostname: $(hostname)'; \
echo 'Current Directory: $(pwd)'; \
echo 'Python version:'; python3 --version; \
echo 'Nextflow version:'; nextflow -version || echo 'Nextflow not found or error getting version.'; \
echo '--- Docker container script finished ---'"
COMMAND_TO_RUN_IN_CONTAINER="${AOC_COMMAND_IN_CONTAINER:-$AOC_DEFAULT_COMMAND}"

# --- Helper Functions ---
log() {
  echo >&2 "[$(date +'%Y-%m-%d %H:%M:%S')] [AoU Pipeline Runner] $@"
}

# --- dsub Helper Function (adapted for AoU environment) ---
# This function defines how 'dsub' is called with AoU-specific parameters.
aou_dsub () {
  if [[ -z "${OWNER_EMAIL:-}" || -z "${GOOGLE_PROJECT:-}" || -z "${WORKSPACE_BUCKET:-}" ]]; then
    log "ERROR: OWNER_EMAIL, GOOGLE_PROJECT, and WORKSPACE_BUCKET environment variables must be set to use aou_dsub."
    return 1
  fi

  local DSUB_USER_NAME
  DSUB_USER_NAME="$(echo "${OWNER_EMAIL}" | cut -d@ -f1)" # Consistent with AoU examples

  # For AoU RWB projects network name is "network".
  local AOU_NETWORK="network"
  local AOU_SUBNETWORK="subnetwork"

  if ! command -v dsub &> /dev/null; then
    log "ERROR: 'dsub' command not found. Please ensure it's installed and in your PATH."
    log "In the All of Us Researcher Workbench terminal, dsub should be available."
    return 1
  fi

  local service_account
  service_account=$(gcloud config get-value account 2>/dev/null)
  if [[ -z "$service_account" ]]; then
    log "WARNING: Could not retrieve account from gcloud config. Using OWNER_EMAIL as fallback for service account."
    service_account="${OWNER_EMAIL}"
  fi

  log "Submitting dsub job with user: ${DSUB_USER_NAME}, project: ${GOOGLE_PROJECT}, service-account: ${service_account}"

  # The --logging path is critical. It uses dsub placeholders.
  # {job-name}, {user-id}, {job-id} will be filled by dsub.
  # The date part in the log path is when dsub processes the job, not when this script runs.
  dsub \
      --provider google-cls-v2 \
      --user-project "${GOOGLE_PROJECT}" \
      --project "${GOOGLE_PROJECT}" \
      --network "${AOU_NETWORK}" \
      --subnetwork "${AOU_SUBNETWORK}" \
      --service-account "${service_account}" \
      --user "${DSUB_USER_NAME}" \
      --regions us-central1 \
      --logging "${WORKSPACE_BUCKET}/dsub/logs/{job-name}/${DSUB_USER_NAME}/$(date +'%Y%m%d')/{job-id}.log" \
      "$@" # Pass through all other arguments (like --image, --script, --name etc.)
}

# --- Main Script ---
log "--- Starting All of Us Docker Container Submission Script ---"
log "Target Docker Image: ${TARGET_IMAGE}"
log "Command to run in container will be written to a temporary script."
log "To customize the command, set AOC_COMMAND_IN_CONTAINER environment variable."

# Check for required AoU environment variables
log "Checking for required environment variables..."
if [[ -z "${WORKSPACE_BUCKET:-}" ]]; then
  log "ERROR: WORKSPACE_BUCKET environment variable is not set."
  log "This is required for dsub logging and potential output in the AoU environment."
  exit 1
fi
log "INFO: WORKSPACE_BUCKET: ${WORKSPACE_BUCKET}"

if [[ -z "${OWNER_EMAIL:-}" ]]; then
  log "ERROR: OWNER_EMAIL environment variable is not set."
  exit 1
fi
log "INFO: OWNER_EMAIL: ${OWNER_EMAIL}"

if [[ -z "${GOOGLE_PROJECT:-}" ]]; then
  log "ERROR: GOOGLE_PROJECT environment variable is not set."
  exit 1
fi
log "INFO: GOOGLE_PROJECT: ${GOOGLE_PROJECT}"


# Create a temporary script that dsub will execute inside the container
# Suffix with .sh for clarity, though not strictly necessary for dsub
DSUB_ENTRYPOINT_SCRIPT_PATH=$(mktemp "/tmp/aou_dsub_entrypoint_XXXXXX.sh")
# Ensure cleanup of the temporary script on exit (normal or error)
trap 'rm -f "${DSUB_ENTRYPOINT_SCRIPT_PATH}"' EXIT

log "Creating temporary dsub entrypoint script at: ${DSUB_ENTRYPOINT_SCRIPT_PATH}"
cat << EOF > "${DSUB_ENTRYPOINT_SCRIPT_PATH}"
#!/bin/bash
set -euo pipefail # Ensure strict mode inside the container script as well

echo "--- dsub entrypoint script started at \$(date) on \$(hostname) ---"
echo "Working directory: \$(pwd)"
echo "User: \$(whoami)"

# Add any environment setup needed within the container *before* the main command
# The PATH should already include /opt/venv/bin from your Dockerfile.

# Execute the user-defined command
${COMMAND_TO_RUN_IN_CONTAINER}

echo "--- dsub entrypoint script finished at \$(date) ---"
EOF
chmod +x "${DSUB_ENTRYPOINT_SCRIPT_PATH}"
log "Temporary dsub entrypoint script created successfully."

# Define dsub job parameters
JOB_NAME_PREFIX="aou-runner"
RANDOM_SUFFIX=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 6)
JOB_NAME="${JOB_NAME_PREFIX}-$(date +%Y%m%d-%H%M%S)-${RANDOM_SUFFIX}"

log "Attempting to submit job to dsub..."
log "Job Name for dsub: ${JOB_NAME}"
log "Image for dsub: ${TARGET_IMAGE}"
log "Script for dsub (will run inside container): ${DSUB_ENTRYPOINT_SCRIPT_PATH}"
# The aou_dsub function will set the --logging path.

DSUB_OUTPUT_FILE=$(mktemp "/tmp/aou_dsub_output_XXXXXX.txt")
# Update trap to clean up both temporary files
trap 'rm -f "${DSUB_ENTRYPOINT_SCRIPT_PATH}" "${DSUB_OUTPUT_FILE}"' EXIT

DSUB_JOB_ID=""
# The `aou_dsub` function outputs to stdout. We capture it.
# Stderr is also redirected to stdout to be captured by TEE_DSUB_OUTPUT.
if TEE_DSUB_OUTPUT=$(aou_dsub \
  --name "${JOB_NAME}" \
  --image "${TARGET_IMAGE}" \
  --script "${DSUB_ENTRYPOINT_SCRIPT_PATH}" \
  --boot-disk-size 50 \
  --disk-size 50 \
  --min-cores 1 \
  --min-ram 4 \
  2>&1) ; then # Capture stdout and stderr together

    echo "${TEE_DSUB_OUTPUT}" > "${DSUB_OUTPUT_FILE}" # Save output for inspection
    log "dsub submission command executed. Full output from dsub call:"
    # Indent the dsub output for clarity in the main log
    while IFS= read -r line; do log "  ${line}"; done < "${DSUB_OUTPUT_FILE}"

    # Try to parse the Google Cloud Life Sciences operation ID
    DSUB_JOB_ID=$(echo "${TEE_DSUB_OUTPUT}" | grep -oE "projects/${GOOGLE_PROJECT}/operations/[0-9]+")

    if [[ -n "${DSUB_JOB_ID}" ]]; then
        log "SUCCESS: dsub job submitted."
        log "dsub Operation ID (Job ID for dstat): ${DSUB_JOB_ID}"

        DSUB_USER_NAME_FOR_DSTAT="$(echo "${OWNER_EMAIL}" | cut -d@ -f1)"
        log "Monitor job status with:"
        log "  dstat --provider google-cls-v2 --project \"${GOOGLE_PROJECT}\" --location us-central1 --users \"${DSUB_USER_NAME_FOR_DSTAT}\" --jobs \"${DSUB_JOB_ID}\" --status '*'"
    else
        log "ERROR: dsub job submitted, but could not parse Operation ID from dsub output."
        log "Please check the dsub output above manually."
        # DSUB_JOB_ID will remain empty, dstat command won't be fully formed
    fi
else
    # This block executes if aou_dsub function itself (or dsub command within it) returns a non-zero exit code.
    echo "${TEE_DSUB_OUTPUT:-"No output captured, aou_dsub might have failed early."}" > "${DSUB_OUTPUT_FILE}"
    log "ERROR: dsub job submission FAILED."
    log "--- dsub Submission Output/Error Start ---"
    cat "${DSUB_OUTPUT_FILE}"
    log "--- dsub Submission Output/Error End ---"
    # Trap will clean up.
    exit 1
fi

# Trap will clean up temporary files.
log "--- All of Us Docker Container Submission Script Finished ---"
exit 0
