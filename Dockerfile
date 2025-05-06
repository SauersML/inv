# Base image with Java 17 (LTS) on Ubuntu Jammy. Nextflow requires Java.
FROM eclipse-temurin:17-jdk-jammy

# --- Configuration ---
ENV PYTHON_VERSION_TARGET=3.11
# Target Nextflow version
ENV NEXTFLOW_VERSION=23.10.1
# Target uv version
ENV UV_VERSION=0.2.7

# Path, locale, and non-interactive frontend settings
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8
ENV DEBIAN_FRONTEND=noninteractive

# --- System Setup ---
# Fail fast if any command in this RUN block fails
RUN set -e && \
    apt-get update -qq && \
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
    # Download precompiled binary directly from GitHub Releases
    echo "Attempting to install uv version ${UV_VERSION} by direct binary download" && \
    mkdir -p /opt/uv_install/bin && \
    # Determine architecture for uv binary download
    DPKG_ARCH=$(dpkg --print-architecture) && \
    case "$DPKG_ARCH" in \
        amd64) UV_PLATFORM_ARCH="x86_64-unknown-linux-gnu";; \
        arm64) UV_PLATFORM_ARCH="aarch64-unknown-linux-gnu";; \
        *) echo "Unsupported architecture for uv binary: $DPKG_ARCH"; exit 1;; \
    esac && \
    curl -LsSf "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${UV_PLATFORM_ARCH}.tar.gz" -o "/tmp/uv.tar.gz" && \
    # Extract only the 'uv' executable directly into the target bin directory
    tar -xzf "/tmp/uv.tar.gz" -C /opt/uv_install/bin uv && \
    rm "/tmp/uv.tar.gz" && \
    # Verify uv installation
    ls -l /opt/uv_install/bin/uv && \
    /opt/uv_install/bin/uv --version && \
    # --- Python Virtual Environment & Package Installation using uv ---
    # Create a virtual environment
    python3 -m venv /opt/venv && \
    # Install Python packages into the venv using the installed uv
    /opt/uv_install/bin/uv pip install --no-cache --python /opt/venv/bin/python \
        google-cloud-bigquery~=3.18.0 \
        pandas~=2.1.4 \
        numpy~=1.26.2 \
        scipy~=1.11.4 \
        google-cloud-storage~=2.14.0 && \
    # --- Nextflow Installation ---
    # Download Nextflow to /opt, then move the executable to /usr/local/bin
    cd /opt && \
    curl -fsSL "https://get.nextflow.io" | bash -s "v${NEXTFLOW_VERSION}" && \
    mv nextflow /usr/local/bin/nextflow && \
    cd / && \
    # --- Cleanup ---
    # Remove build-only dependencies and PPA config to reduce image size
    apt-get purge -y --auto-remove build-essential software-properties-common gnupg && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /root/.cache

# --- Application Setup ---
WORKDIR /opt/analysis_workspace

# Final PATH configuration
# Add the Python virtual environment's bin and uv's bin to PATH.
# /usr/local/bin (where nextflow is) is typically in PATH by default.
# PYTHONPATH is not set as no custom scripts are being added from a 'bin/' directory.
ENV PATH="/opt/venv/bin:/opt/uv_install/bin:${PATH}"

# --- Default Command ---
# Provides a basic test of the image; Nextflow will override this for task execution.
CMD ["nextflow", "info"]
