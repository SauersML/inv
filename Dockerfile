# Base image with Java 17 (LTS) on Ubuntu Jammy. Nextflow requires Java.
FROM eclipse-temurin:17-jdk-jammy

# --- Configuration ---
ENV PYTHON_VERSION_TARGET=3.11
ENV NEXTFLOW_VERSION=23.10.1
ENV UV_VERSION=0.1.11 # Check for the latest stable uv version

# Path, locale, and non-interactive frontend settings
ENV PATH="/opt/nextflow:/opt/uv_install/bin:${PATH}"
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8
ENV DEBIAN_FRONTEND=noninteractive

# --- System Setup ---
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        software-properties-common \
        git \
        unzip \
        wget \
        build-essential \
        libssl-dev \
        zlib1g-dev \
        libbz2-dev \
        libreadline-dev \
        libsqlite3-dev \
        llvm \
        libncursesw5-dev \
        xz-utils \
        tk-dev \
        libffi-dev \
        liblzma-dev && \
    # --- Python Installation (using deadsnakes PPA for specific version) ---
    add-apt-repository ppa:deadsnakes/ppa -y && \
    apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        "python${PYTHON_VERSION_TARGET}" \
        "python${PYTHON_VERSION_TARGET}-dev" \
        "python${PYTHON_VERSION_TARGET}-venv" && \
    # Set python3 to point to the installed Python version
    update-alternatives --install /usr/bin/python3 python3 "/usr/bin/python${PYTHON_VERSION_TARGET}" 1 && \
    # --- uv Installation (Fast Python Package Installer) ---
    # Download and install uv to a specific location
    mkdir -p /opt/uv_install && \
    curl -LsSf https://astral.sh/uv/install.sh | sh -s -- --version "${UV_VERSION}" --dest /opt/uv_install/bin && \
    # Verify uv installation
    /opt/uv_install/bin/uv --version && \
    # --- Python Virtual Environment & Package Installation using uv ---
    # Create a virtual environment managed by uv
    python3 -m venv /opt/venv && \
    /opt/uv_install/bin/uv pip install --no-cache --python /opt/venv/bin/python \
        # Specify Python packages with desired versions or ranges
        # Using '~=' for patch-level compatibility is a good practice for stability
        google-cloud-bigquery~=3.18.0 \
        pandas~=2.1.4 \
        numpy~=1.26.2 \
        scipy~=1.11.4 \
        google-cloud-storage~=2.14.0 && \
    # --- Nextflow Installation ---
    cd /opt && \
    curl -fsSL "https://get.nextflow.io" | bash -s "v${NEXTFLOW_VERSION}" && \
    mv nextflow /usr/local/bin/nextflow && \
    # --- Cleanup ---
    # Remove build-only dependencies and PPA config
    apt-get purge -y --auto-remove build-essential software-properties-common gnupg && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /root/.cache

# --- Application Setup ---
# Define a consistent workspace directory
WORKDIR /opt/analysis_workspace

# Copy application-specific scripts from the 'bin' directory in the build context
COPY bin/ /opt/analysis_workspace/bin/

# Make scripts executable
RUN chmod +x /opt/analysis_workspace/bin/*.py

# Add the application scripts directory to PYTHONPATH
# Also, make the venv's python the default python for subsequent RUN/CMD/ENTRYPOINT
ENV PYTHONPATH=/opt/analysis_workspace/bin:${PYTHONPATH} \
    PATH="/opt/venv/bin:${PATH}"

# --- Default Command ---
# Useful for image introspection; Nextflow will override this for task execution.
CMD ["nextflow", "info"]
