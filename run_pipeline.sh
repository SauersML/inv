#!/bin/bash

# Exit on error, treat unset variables as errors, fail pipelines
set -euo pipefail

# --- Configuration ---
# Target Docker image (contains Nextflow, tools, and pipeline scripts)
readonly TARGET_IMAGE="sauers/runner:latest"

# Paths to Nextflow components inside the Docker container
readonly NEXTFLOW_SCRIPT_PATH_IN_IMAGE="/opt/analysis_workspace/main.nf"
readonly NEXTFLOW_CONFIG_PATH_IN_IMAGE="/opt/analysis_workspace/nextflow.config"

# Working directory for Nextflow inside the container
readonly NEXTFLOW_WORK_DIR_IN_CONTAINER="/mnt/data/workingdir/nf_work"

# Environment variable NAME that dsub will set for the Nextflow output directory path
readonly DSUB_NEXTFLOW_OUTPUT_DIR_ENV_VAR="NF_RESULTS_DIR"

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

# 2. Construct the command that will be executed inside the dsub container
# This launches the Nextflow pipeline.
# Nextflow reads data paths from its config, and output dir from the dsub-set env var.
readonly COMMAND_TO_RUN_IN_CONTAINER="
echo \"[DSUB ENTRYPOINT] Launching Nextflow pipeline...\"
echo \"[DSUB ENTRYPOINT] Nextflow script: ${NEXTFLOW_SCRIPT_PATH_IN_IMAGE}\"
echo \"[DSUB ENTRYPOINT] Nextflow config: ${NEXTFLOW_CONFIG_PATH_IN_IMAGE}\"
echo \"[DSUB ENTRYPOINT] Nextflow work directory (local): ${NEXTFLOW_WORK_DIR_IN_CONTAINER}\"
echo \"[DSUB ENTRYPOINT] Nextflow output directory (from env var \$${DSUB_NEXTFLOW_OUTPUT_DIR_ENV_VAR}): \$${DSUB_NEXTFLOW_OUTPUT_DIR_ENV_VAR}\"
echo \"[DSUB ENTRYPOINT] Main container image (for Nextflow tasks): ${TARGET_IMAGE}\"

# Ensure the output directory dsub provides exists
if [[ -z \"\${${DSUB_NEXTFLOW_OUTPUT_DIR_ENV_VAR}:-}\" ]]; then
    echo \"[DSUB ENTRYPOINT] ERROR: Output directory env var \$${DSUB_NEXTFLOW_OUTPUT_DIR_ENV_VAR} not set by dsub or is empty!\"
    exit 1
fi
mkdir -p \"\${${DSUB_NEXTFLOW_OUTPUT_DIR_ENV_VAR}}\"
echo \"[DSUB ENTRYPOINT] Ensured local Nextflow output directory exists: \${${DSUB_NEXTFLOW_OUTPUT_DIR_ENV_VAR}}\"

nextflow run \"${NEXTFLOW_SCRIPT_PATH_IN_IMAGE}\" \\
    -c \"${NEXTFLOW_CONFIG_PATH_IN_IMAGE}\" \\
    --output_dir_local \"\${${DSUB_NEXTFLOW_OUTPUT_DIR_ENV_VAR}}\" \\
    -profile standard \\
    -work-dir \"${NEXTFLOW_WORK_DIR_IN_CONTAINER}\" \\
    -with-docker \"${TARGET_IMAGE}\" \\
    -resume

NEXTFLOW_EXIT_CODE=\$?
echo \"[DSUB ENTRYPOINT] Nextflow execution finished with exit code: \${NEXTFLOW_EXIT_CODE}\"

echo \"[DSUB ENTRYPOINT] Listing contents of Nextflow output directory (\${${DSUB_NEXTFLOW_OUTPUT_DIR_ENV_VAR}}):\"
ls -laR \"\${${DSUB_NEXTFLOW_OUTPUT_DIR_ENV_VAR}}\" || echo \"[WARN] Could not list Nextflow output directory contents.\"

exit \${NEXTFLOW_EXIT_CODE}
"

# Create the temporary dsub entrypoint script
DSUB_ENTRYPOINT_SCRIPT_PATH=$(mktemp "/tmp/dsub_nf_entrypoint_XXXXXX.sh")
trap 'rm -f "${DSUB_ENTRYPOINT_SCRIPT_PATH}"' EXIT # Cleanup on exit
log_submitter "INFO: Creating dsub entrypoint script: ${DSUB_ENTRYPOINT_SCRIPT_PATH}"
cat << EOF > "${DSUB_ENTRYPOINT_SCRIPT_PATH}"
#!/bin/bash
set -euo pipefail
echo "--- dsub entrypoint started: \$(date) on \$(hostname) ---"
echo "--- Working directory: \$(pwd) ---"
echo "--- User: \$(whoami) ---"
${COMMAND_TO_RUN_IN_CONTAINER}
echo "--- dsub entrypoint finished: \$(date) ---"
EOF
chmod +x "${DSUB_ENTRYPOINT_SCRIPT_PATH}"

# 3. Define dsub Job Name and GCS Output Path for dsub
JOB_NAME_PREFIX="aou-nf-vcfqc-final"
RANDOM_SUFFIX=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 6)
JOB_NAME="${JOB_NAME_PREFIX}-$(date +%Y%m%d-%H%M%S)-${RANDOM_SUFFIX}"
GCS_FINAL_RESULTS_PATH="${WORKSPACE_BUCKET}/dsub_results/${JOB_NAME}/pipeline_outputs/"

log_submitter "INFO: Submitting dsub job named: ${JOB_NAME}"
log_submitter "INFO: Using image: ${TARGET_IMAGE}"
log_submitter "INFO: Final Nextflow results will be copied by dsub to: ${GCS_FINAL_RESULTS_PATH}"

# 4. Submit the job using dsub
DSUB_SUBMIT_OUTPUT_CAPTURE=$(mktemp "/tmp/dsub_submit_output_XXXXXX.txt")
trap 'rm -f "${DSUB_ENTRYPOINT_SCRIPT_PATH}" "${DSUB_SUBMIT_OUTPUT_CAPTURE}"' EXIT # Update trap

LAUNCHED_DSUB_JOB_ID=""
SUBMISSION_EXIT_STATUS=-1

DSUB_USER_SHORTNAME="$(echo "${OWNER_EMAIL}" | cut -d@ -f1)"
DSUB_SERVICE_ACCOUNT="$(gcloud config get-value account 2>/dev/null || echo "${OWNER_EMAIL}")"

log_submitter "INFO: Submitting with User=${DSUB_USER_SHORTNAME}, Project=${GOOGLE_PROJECT}, SA=${DSUB_SERVICE_ACCOUNT}"

if { dsub \
      --provider google-cls-v2 \
      --project "${GOOGLE_PROJECT}" \
      --user-project "${GOOGLE_PROJECT}" \
      --user "${DSUB_USER_SHORTNAME}" \
      --service-account "${DSUB_SERVICE_ACCOUNT}" \
      --network "network" \
      --subnetwork "subnetwork" \
      --regions "us-central1" \
      --logging "${WORKSPACE_BUCKET}/dsub/logs/{job-name}/${DSUB_USER_SHORTNAME}/$(date +'%Y%m%d')/{job-id}.log" \
      --name "${JOB_NAME}" \
      --image "${TARGET_IMAGE}" \
      --script "${DSUB_ENTRYPOINT_SCRIPT_PATH}" \
      --output-recursive "${DSUB_NEXTFLOW_OUTPUT_DIR_ENV_VAR}=${GCS_FINAL_RESULTS_PATH}" \
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
        log_submitter "SUCCESS: dsub job submitted!"
        log_submitter "--> dsub Job ID: ${LAUNCHED_DSUB_JOB_ID}"
        
        # Construct the dstat command using the globally available DSUB_USER_SHORTNAME
        DSTAT_COMMAND="dstat --provider google-cls-v2 --project \"${GOOGLE_PROJECT}\" --location us-central1 --users \"${DSUB_USER_SHORTNAME}\" --jobs '${LAUNCHED_DSUB_JOB_ID}' --status '*' --full"
        
        log_submitter "--> For detailed status, you can run this in another terminal if needed:"
        echo 
        echo "    ${DSTAT_COMMAND}"
        echo 
        
        # Construct the GCS log path for this specific job
        LOG_DATE_FOR_PATH=$(date +'%Y%m%d') 
        GCS_LOG_PATH="${WORKSPACE_BUCKET}/dsub/logs/${JOB_NAME}/${DSUB_USER_SHORTNAME}/${LOG_DATE_FOR_PATH}/${LAUNCHED_DSUB_JOB_ID}.log"

        log_submitter "--> Attempting to stream logs from: ${GCS_LOG_PATH}"
        log_submitter "    (This requires gcloud alpha components. Press Ctrl+C to stop tailing.)"
        log_submitter "    (Allowing up to 30 seconds for log file to be created by dsub...)"
        
        LOG_FILE_EXISTS=false
        for i in {1..6}; do # Check every 5 seconds for up to 30 seconds
            if gsutil -u "${GOOGLE_PROJECT}" stat "${GCS_LOG_PATH}" &>/dev/null; then
                log_submitter "    Log file found. Starting tail..."
                LOG_FILE_EXISTS=true
                break
            else
                log_submitter "    Log file not yet found, waiting 5s (attempt $i/6)..."
                sleep 5
            fi
        done

        if [[ "${LOG_FILE_EXISTS}" == true ]]; then
            if command -v gcloud &> /dev/null && gcloud alpha storage help &> /dev/null; then
                echo
                log_submitter ">>> Streaming logs (Press Ctrl+C to stop stream and end this script):"
                # The trap for EXIT will clean up temp files when Ctrl+C is pressed here.
                gcloud alpha storage tail --project="${GOOGLE_PROJECT}" "${GCS_LOG_PATH}" || \
                    log_submitter "WARN: 'gcloud alpha storage tail' ended. This might be due to an error, job completion, or Ctrl+C."
                echo
            else
                log_submitter "WARN: 'gcloud alpha storage tail' command not found or 'gcloud alpha' components not installed."
                log_submitter "      Please monitor job using the dstat command and check GCS log path manually: ${GCS_LOG_PATH}"
            fi
        else
            log_submitter "ERROR: Log file was not found at ${GCS_LOG_PATH} after 30 seconds."
            log_submitter "       Please monitor job using the dstat command."
        fi
    else
        log_submitter "ERROR: dsub job submitted, but could not parse Job ID from output:"
        cat "${DSUB_SUBMIT_OUTPUT_CAPTURE}" >&2
    fi
else
    [[ "$SUBMISSION_EXIT_STATUS" == -1 ]] && SUBMISSION_EXIT_STATUS=$?
    log_submitter "ERROR: dsub job submission FAILED (Exit Status: ${SUBMISSION_EXIT_STATUS}). See output below:"
    cat "${DSUB_SUBMIT_OUTPUT_CAPTURE}" >&2
    exit 1
fi

log_submitter "--- dsub Job Submission Script Finished (Log tailing may have been interrupted) ---"
exit 0
