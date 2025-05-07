#!/bin/bash

# Strict mode: exit on error, exit on unset variable, fail pipelines
set -euo pipefail

# --- Configuration ---
GHCR_REGISTRY="ghcr.io"
# REPO_URL: https://github.com/SauersML/inv.git
GITHUB_OWNER="SauersML"
# From env.IMAGE_BASE_NAME in GHA workflow
IMAGE_BASE_NAME="aou-analysis-runner"
IMAGE_VERSION="latest" # The GHA workflow pushes 'latest' for the main branch

# Construct the full image path for GHCR
TARGET_IMAGE="${GHCR_REGISTRY}/${GITHUB_OWNER}/${IMAGE_BASE_NAME}:${IMAGE_VERSION}"

# EXPECTED_SCRIPT_PATH_IN_IMAGE="/app/bin/haplotype_assoc.py" # wrong
COMMAND_IN_CONTAINER="python3 ${EXPECTED_SCRIPT_PATH_IN_IMAGE} --help"
COMMAND_IN_CONTAINER="python3 --version"

# Log file configuration
LOG_DIR="docker_ghcr_test_logs"
SCRIPT_LOG_FILE="${LOG_DIR}/script_execution_$(date +%Y%m%d_%H%M%S).log"
DOCKER_LOGIN_LOG_FILE="${LOG_DIR}/docker_login.log"
DOCKER_PULL_LOG_FILE="${LOG_DIR}/docker_pull.log"
DOCKER_RUN_LOG_FILE="${LOG_DIR}/docker_run_command.log"

# --- Helper Functions ---
_log_to_file() {
  # Ensures log directory exists
  mkdir -p "${LOG_DIR}"
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $@" >> "${SCRIPT_LOG_FILE}"
}

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $@" | tee -a "${SCRIPT_LOG_FILE}"
}

# --- Main Script ---

# Initialize script log file
mkdir -p "${LOG_DIR}"
echo "--- Script Execution Log ---" > "${SCRIPT_LOG_FILE}" # Overwrite/create new log for this run
_log_to_file "Script started." # Use _log_to_file for initial internal logging

log "--- Starting Docker Image Pull & Run Test from GHCR ---"
log "INFO: Target Docker Image: ${TARGET_IMAGE}"
log "INFO: Command to run in container: ${COMMAND_IN_CONTAINER}"
log "INFO: All detailed logs will be stored in ./${LOG_DIR}/"

# Check for Docker
if ! command -v docker &> /dev/null; then
    log "ERROR: 'docker' command not found. Please install Docker."
    _log_to_file "Docker command not found. Exiting."
    exit 1
fi
log "INFO: Docker command found: $(command -v docker)"
log "INFO: Docker version: $(docker --version | tee -a "${SCRIPT_LOG_FILE}")"

# Pull Docker Image from GHCR
log "[Step 2/3] Pulling Docker image ${TARGET_IMAGE} from GHCR..."
echo "--- Docker Pull Log for ${TARGET_IMAGE} ---" > "${DOCKER_PULL_LOG_FILE}"
log "Executing: docker pull \"${TARGET_IMAGE}\""
if docker pull "${TARGET_IMAGE}" >> "${DOCKER_PULL_LOG_FILE}" 2>&1; then
    log "SUCCESS: Docker image ${TARGET_IMAGE} pulled successfully."
    log "Details logged to: ${PWD}/${DOCKER_PULL_LOG_FILE}"
    _log_to_file "Docker pull successful. Image details from log:"
    cat "${DOCKER_PULL_LOG_FILE}" >> "${SCRIPT_LOG_FILE}"
    log "--- Pulled Image Info ---"
    docker images "${TARGET_IMAGE}" | tee -a "${SCRIPT_LOG_FILE}"
else
    log "ERROR: Failed to pull Docker image ${TARGET_IMAGE}."
    log "Details in: ${PWD}/${DOCKER_PULL_LOG_FILE}"
    cat "${DOCKER_PULL_LOG_FILE}" >> "${SCRIPT_LOG_FILE}"
    _log_to_file "Docker pull failed. Exiting."
    exit 1
fi
_log_to_file "Docker pull step completed."

# Run Test Command in Docker Image
log "[Step 3/3] Running test command in the pulled Docker image ${TARGET_IMAGE}..."
log "Executing: docker run --rm \"${TARGET_IMAGE}\" ${COMMAND_IN_CONTAINER}"
echo "--- Docker Run Command Log: docker run --rm \"${TARGET_IMAGE}\" ${COMMAND_IN_CONTAINER} ---" > "${DOCKER_RUN_LOG_FILE}"

TMP_DOCKER_RUN_OUTPUT_FILE=$(mktemp)
# Run the command, capturing both stdout and stderr to the temp file and the log file simultaneously
if docker run --rm "${TARGET_IMAGE}" ${COMMAND_IN_CONTAINER} > "${TMP_DOCKER_RUN_OUTPUT_FILE}" 2>&1; then
    log "SUCCESS: Command executed successfully in Docker image ${TARGET_IMAGE}."
    log "--- Command Output Start ---"
    cat "${TMP_DOCKER_RUN_OUTPUT_FILE}" | tee -a "${DOCKER_RUN_LOG_FILE}" | tee -a "${SCRIPT_LOG_FILE}"
    log "--- Command Output End ---"
    log "Full command output logged to: ${PWD}/${DOCKER_RUN_LOG_FILE}"
else
    RUN_EXIT_CODE=$?
    log "ERROR: Command execution FAILED in Docker image ${TARGET_IMAGE} (Exit Code: ${RUN_EXIT_CODE})."
    log "--- Command Output/Error Start ---"
    cat "${TMP_DOCKER_RUN_OUTPUT_FILE}" | tee -a "${DOCKER_RUN_LOG_FILE}" | tee -a "${SCRIPT_LOG_FILE}"
    log "--- Command Output/Error End ---"
    log "Full command output/error logged to: ${PWD}/${DOCKER_RUN_LOG_FILE}"
    _log_to_file "Docker run command failed. Exiting."
    rm -f "${TMP_DOCKER_RUN_OUTPUT_FILE}"
    exit 1
fi
rm -f "${TMP_DOCKER_RUN_OUTPUT_FILE}"
_log_to_file "Docker run step completed."

log "--- Docker Image Pull & Run Test from GHCR Finished Successfully ---"
log "All logs collected in directory: ${PWD}/${LOG_DIR}"
_log_to_file "Script finished successfully."
exit 0
