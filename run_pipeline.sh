#!/bin/bash

# Exit on error, treat unset variables as errors, fail pipelines
set -euo pipefail

# --- Configuration ---
# Target Docker image
readonly TARGET_IMAGE="sauers/runner:latest"

# Paths to Nextflow components inside the container
readonly NEXTFLOW_SCRIPT_PATH_IN_IMAGE="/opt/analysis_workspace/main.nf"
readonly NEXTFLOW_CONFIG_PATH_IN_IMAGE="/opt/analysis_workspace/nextflow.config"

# Working directory for Nextflow inside the container
# dsub typically provides /mnt/data/workingdir
readonly NEXTFLOW_WORK_DIR_IN_CONTAINER="/mnt/data/workingdir/nf_work"

# --- Define the single command to run inside the container ---
# This launches the Nextflow pipeline.
# Nextflow reads all parameters (GCS paths, region, output dir) from its config file.
readonly COMMAND_TO_RUN_IN_CONTAINER="
echo '[INFO] Launching Nextflow pipeline...'
nextflow run ${NEXTFLOW_SCRIPT_PATH_IN_IMAGE} \\
    -c ${NEXTFLOW_CONFIG_PATH_IN_IMAGE} \\
    -profile standard \\
    -work-dir \"${NEXTFLOW_WORK_DIR_IN_CONTAINER}\" \\
    -with-docker \"${TARGET_IMAGE}\" \\
    -resume
exit \$? # Exit dsub script with Nextflow's exit code
"

# --- Helper Function: Minimal Logging ---
log_submitter() {
  echo >&2 "[$(date +'%Y-%m-%d %H:%M:%S')] [dsub Submitter] $@"
}

# --- dsub Submission Logic ---

# 1. Check essential AoU Environment Variables needed for dsub submission
log_submitter "Verifying required AoU environment variables..."
if [[ -z "${WORKSPACE_BUCKET:-}" ]]; then log_submitter "ERROR: WORKSPACE_BUCKET not set."; exit 1; fi
if [[ -z "${OWNER_EMAIL:-}" ]]; then log_submitter "ERROR: OWNER_EMAIL not set."; exit 1; fi
if [[ -z "${GOOGLE_PROJECT:-}" ]]; then log_submitter "ERROR: GOOGLE_PROJECT not set."; exit 1; fi
log_submitter "INFO: Using Project=${GOOGLE_PROJECT}, Bucket=${WORKSPACE_BUCKET}, Submitter=${OWNER_EMAIL}"

# 2. Create the temporary dsub entrypoint script
DSUB_ENTRYPOINT_SCRIPT_PATH=$(mktemp "/tmp/dsub_nf_entrypoint_XXXXXX.sh")
trap 'rm -f "${DSUB_ENTRYPOINT_SCRIPT_PATH}"' EXIT # Cleanup on exit
log_submitter "INFO: Creating dsub entrypoint script: ${DSUB_ENTRYPOINT_SCRIPT_PATH}"
cat << EOF > "${DSUB_ENTRYPOINT_SCRIPT_PATH}"
#!/bin/bash
set -euo pipefail
echo "--- dsub entrypoint started: \$(date) on \$(hostname) ---"
pwd
whoami
${COMMAND_TO_RUN_IN_CONTAINER}
echo "--- dsub entrypoint finished: \$(date) ---"
EOF
chmod +x "${DSUB_ENTRYPOINT_SCRIPT_PATH}"

# 3. Define dsub Job Name and Output Path
JOB_NAME_PREFIX="aou-nf-vcfqc-fixed" # Specific prefix
RANDOM_SUFFIX=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 6)
JOB_NAME="${JOB_NAME_PREFIX}-$(date +%Y%m%d-%H%M%S)-${RANDOM_SUFFIX}"
# Define where Nextflow saves outputs locally (must match params.output_dir_local in nextflow.config)
NEXTFLOW_LOCAL_OUTPUT_PATH="/mnt/data/workingdir/pipeline_results"
# Define the final GCS destination for those outputs
GCS_OUTPUT_PATH="${WORKSPACE_BUCKET}/dsub_results/${JOB_NAME}/pipeline_results/"

log_submitter "INFO: Submitting dsub job named: ${JOB_NAME}"
log_submitter "INFO: Using image: ${TARGET_IMAGE}"
log_submitter "INFO: Final results will be copied to: ${GCS_OUTPUT_PATH}"

# 4. Submit the job using dsub (capturing output to parse Job ID)
DSUB_SUBMIT_OUTPUT_CAPTURE=$(mktemp "/tmp/dsub_submit_output_XXXXXX.txt")
trap 'rm -f "${DSUB_ENTRYPOINT_SCRIPT_PATH}" "${DSUB_SUBMIT_OUTPUT_CAPTURE}"' EXIT # Update trap

LAUNCHED_DSUB_JOB_ID=""
SUBMISSION_EXIT_STATUS=-1

if { dsub \
      --provider google-cls-v2 \
      --project "${GOOGLE_PROJECT}" \
      --user-project "${GOOGLE_PROJECT}" \
      --user "$(echo "${OWNER_EMAIL}" | cut -d@ -f1)" \
      --service-account "$(gcloud config get-value account 2>/dev/null || echo ${OWNER_EMAIL})" \
      --network "network" \
      --subnetwork "subnetwork" \
      --regions "us-central1" \
      --logging "${WORKSPACE_BUCKET}/dsub/logs/{job-name}/$(echo ${OWNER_EMAIL} | cut -d@ -f1)/$(date +'%Y%m%d')/{job-id}.log" \
      --name "${JOB_NAME}" \
      --image "${TARGET_IMAGE}" \
      --script "${DSUB_ENTRYPOINT_SCRIPT_PATH}" \
      --output-recursive "${NEXTFLOW_LOCAL_OUTPUT_PATH}=${GCS_OUTPUT_PATH}" \
      --min-cores 2 \
      --min-ram 8 \
      --disk-size 150 \
      --boot-disk-size 50 \
      2>&1 | tee "${DSUB_SUBMIT_OUTPUT_CAPTURE}"; \
      SUBMISSION_EXIT_STATUS=${PIPESTATUS[0]}; \
      (( SUBMISSION_EXIT_STATUS == 0 )); \
    }; then

    log_submitter "INFO: dsub submission command finished successfully."
    LAUNCHED_DSUB_JOB_ID=$(grep 'Launched job-id:' "${DSUB_SUBMIT_OUTPUT_CAPTURE}" | awk '{print $NF}')

    if [[ -n "${LAUNCHED_DSUB_JOB_ID}" ]]; then
        log_submitter "SUCCESS: dsub job submitted."
        log_submitter "--> dsub Job ID: ${LAUNCHED_DSUB_JOB_ID}"
        
        # Construct the exact dstat command for monitoring THIS job
        DSUB_USER_FOR_MONITOR="$(echo "${OWNER_EMAIL}" | cut -d@ -f1)"
        DSTAT_COMMAND="dstat --provider google-cls-v2 --project \"${GOOGLE_PROJECT}\" --location us-central1 --users \"${DSUB_USER_FOR_MONITOR}\" --jobs '${LAUNCHED_DSUB_JOB_ID}' --status '*' --full"
        
        log_submitter "--> To monitor status, run:"
        echo 
        echo "${DSTAT_COMMAND}"
        echo # Add a newline after the command
        log_submitter "--> To attempt near-real-time logs (requires gcloud alpha, may have latency):"
        log_submitter "    Run the command above, find the 'logging:' GCS path, then run:"
        log_submitter "    gcloud alpha storage tail --project=\"${GOOGLE_PROJECT}\" \"GCS_LOG_PATH_FROM_DSTAT\""

    else
        log_submitter "ERROR: dsub job submitted, but could not parse Job ID from output:"
        cat "${DSUB_SUBMIT_OUTPUT_CAPTURE}" >&2 # Send dsub output to stderr on parsing error
    fi
else
    [[ "$SUBMISSION_EXIT_STATUS" == -1 ]] && SUBMISSION_EXIT_STATUS=$?
    log_submitter "ERROR: dsub job submission FAILED (Exit Status: ${SUBMISSION_EXIT_STATUS}). See output below:"
    cat "${DSUB_SUBMIT_OUTPUT_CAPTURE}" >&2 # Send dsub output to stderr on failure
    exit 1
fi

log_submitter "--- dsub Job Submission Script Finished ---"
exit 0
