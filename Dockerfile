# Base image with Java 17 (LTS) on Ubuntu Jammy. Nextflow requires Java.
FROM eclipse-temurin:17-jdk-jammy

# --- Configuration ---
ENV PYTHON_VERSION_TARGET=3.11
# Target Nextflow version
ENV NEXTFLOW_VERSION=23.10.1

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
        "python${PYTHON_VERSION_TARGET}-venv" \
        python3-pip && \
    # Set python3 to point to the installed Python version
    update-alternatives --install /usr/bin/python3 python3 "/usr/bin/python${PYTHON_VERSION_TARGET}" 1 && \
    # --- Python Virtual Environment & Package Installation using pip ---
    # Create a virtual environment
    python3 -m venv /opt/venv && \
    # Upgrade pip within the virtual environment
    /opt/venv/bin/python3 -m pip install --no-cache-dir --upgrade pip setuptools wheel && \
    # Install Python packages into the venv using the venv's pip
    /opt/venv/bin/pip install --no-cache-dir \
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

ENV PATH="/opt/venv/bin:${PATH}"

# --- Default Command ---
# Provides a basic test of the image; Nextflow will override this for task execution.
CMD ["nextflow", "info"]
