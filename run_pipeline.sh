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
JOB_NAME_PREFIX="aou-nf-vcfqc-poll" # Updated prefix
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
        
        # --- Start Polling Job Status ---
        log_submitter "--> Now polling job status for ${LAUNCHED_DSUB_JOB_ID} every 30 seconds (Press Ctrl+C to stop this script and polling):"
        
        POLLING_INTERVAL=30 # seconds
        # Max attempts if dstat initially doesn't find the job (e.g., 6 attempts * 5s sleep = 30s for job to appear)
        MAX_INITIAL_NOT_FOUND_ATTEMPTS=6 
        INITIAL_NOT_FOUND_COUNT=0
        
        FINAL_STATUS_OBTAINED=false
        GCS_LOG_PATH_FROM_DSTAT="" # Store the GCS log path once found
        JOB_CURRENT_OVERALL_STATUS="PENDING_SUBMISSION" # Initial state

        # Give the backend a moment before first dstat query
        log_submitter "[POLLING] Initial short wait for job to register with backend..."
        sleep 5 

        while [[ "${FINAL_STATUS_OBTAINED}" == false ]]; do
            DSTAT_FULL_OUTPUT=$(dstat --provider google-cls-v2 --project "${GOOGLE_PROJECT}" --location us-central1 --users "${DSUB_USER_SHORTNAME}" --jobs "${LAUNCHED_DSUB_JOB_ID}" --status '*' --full 2>/dev/null || echo "DSTAT_COMMAND_ERROR")

            if [[ "${DSTAT_FULL_OUTPUT}" == "DSTAT_COMMAND_ERROR" ]]; then
                log_submitter "[POLLING] WARN: dstat command failed. Will retry in ${POLLING_INTERVAL}s."
                # Do not increment INITIAL_NOT_FOUND_COUNT if dstat itself fails
            elif [[ -z "${DSTAT_FULL_OUTPUT}" || "${DSTAT_FULL_OUTPUT}" == "[]" ]]; then # dstat returns "[]" for no jobs
                ((INITIAL_NOT_FOUND_COUNT++))
                if (( INITIAL_NOT_FOUND_COUNT >= MAX_INITIAL_NOT_FOUND_ATTEMPTS )); then
                    log_submitter "[POLLING] ERROR: Job ${LAUNCHED_DSUB_JOB_ID} still not found by dstat after ${INITIAL_NOT_FOUND_COUNT} attempts. Stopping poll. Please check manually."
                    FINAL_STATUS_OBTAINED=true # Exit loop
                else
                    log_submitter "[POLLING] WARN: Job ${LAUNCHED_DSUB_JOB_ID} not yet visible to dstat (attempt ${INITIAL_NOT_FOUND_COUNT}/${MAX_INITIAL_NOT_FOUND_ATTEMPTS}). Retrying in ${POLLING_INTERVAL}s..."
                fi
            else
                # Job found by dstat, reset initial not found counter
                INITIAL_NOT_FOUND_COUNT=0 
                
                TEMP_JOB_STATUS=$(echo "${DSTAT_FULL_OUTPUT}"       | grep -E '^status:'          | awk '{print $2}'          || true)
                TEMP_STATUS_DETAIL=$(echo "${DSTAT_FULL_OUTPUT}"    | grep -E '^status-detail:'    | sed 's/status-detail: //' || true)
                TEMP_LAST_UPDATE=$(echo "${DSTAT_FULL_OUTPUT}"      | grep -E '^last-update:'      | awk '{print $2}'          || true)
                
                # Update JOB_CURRENT_OVERALL_STATUS only if successfully parsed
                if [[ -n "${TEMP_JOB_STATUS}" ]]; then
                    JOB_CURRENT_OVERALL_STATUS="${TEMP_JOB_STATUS}"
                fi

                # Extract GCS Log Path once if not already found
                if [[ -z "$GCS_LOG_PATH_FROM_DSTAT" ]]; then 
                    TEMP_GCS_LOG_PATH=$(echo "${DSTAT_FULL_OUTPUT}" | grep -E '^logging:'          | awk '{print $2}'          || true)
                    if [[ -n "${TEMP_GCS_LOG_PATH}" ]]; then
                        GCS_LOG_PATH_FROM_DSTAT="${TEMP_GCS_LOG_PATH}"
                    fi
                fi

                log_submitter "[POLLING $(date +'%Y-%m-%d %H:%M:%S')] Job: ${LAUNCHED_DSUB_JOB_ID} | Status: ${JOB_CURRENT_OVERALL_STATUS} | Detail: ${TEMP_STATUS_DETAIL} | LastUpdate: ${TEMP_LAST_UPDATE}"

                if [[ "${JOB_CURRENT_OVERALL_STATUS}" == "SUCCESS" || "${JOB_CURRENT_OVERALL_STATUS}" == "FAILURE" || "${JOB_CURRENT_OVERALL_STATUS}" == "CANCELED" ]]; then
                    log_submitter "[POLLING] Job has reached a terminal state: ${JOB_CURRENT_OVERALL_STATUS}."
                    FINAL_STATUS_OBTAINED=true
                fi
            fi
            
            if [[ "${FINAL_STATUS_OBTAINED}" == false ]]; then
                sleep "${POLLING_INTERVAL}"
            fi
        done # End of while polling loop

        log_submitter "--> Polling finished for job ${LAUNCHED_DSUB_JOB_ID}."
        log_submitter "    Final reported status: ${JOB_CURRENT_OVERALL_STATUS}"
        
        # Display final dstat output again for completeness
        log_submitter "--> Final detailed dstat output for ${LAUNCHED_DSUB_JOB_ID}:"
        echo
        dstat --provider google-cls-v2 --project "${GOOGLE_PROJECT}" --location us-central1 --users "${DSUB_USER_SHORTNAME}" --jobs "${LAUNCHED_DSUB_JOB_ID}" --status '*' --full 2>/dev/null || echo "[POLLING] WARN: Could not get final dstat output for completed/failed job."
        echo

        if [[ -n "$GCS_LOG_PATH_FROM_DSTAT" ]]; then # If we successfully got the log path from dstat
             log_submitter "    View full logs at: ${GCS_LOG_PATH_FROM_DSTAT}"
             log_submitter "    Use command: gsutil cat ${GCS_LOG_PATH_FROM_DSTAT}"
        else
             # Fallback if log path was not found during polling (e.g., job completed extremely fast before dstat showed it)
             LOG_DATE_FOR_PATH=$(date +'%Y%m%d') # Use current date as used by dsub logging
             FALLBACK_GCS_LOG_PATH="${WORKSPACE_BUCKET}/dsub/logs/${JOB_NAME}/${DSUB_USER_SHORTNAME}/${LOG_DATE_FOR_PATH}/${LAUNCHED_DSUB_JOB_ID}.log"
             log_submitter "    Could not determine GCS log path from dstat polling (job might have completed very quickly or dstat failed)."
             log_submitter "    A likely log path is: ${FALLBACK_GCS_LOG_PATH}"
             log_submitter "    Use command: gsutil cat ${FALLBACK_GCS_LOG_PATH}"
        fi
        # --- End Polling Job Status ---
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

log_submitter "--- dsub Job Submission Script Finished ---"
exit 0
