# Base image with Java 17 (LTS) on Ubuntu Jammy. Nextflow requires Java.
FROM eclipse-temurin:17-jdk-jammy

ENV PYTHON_VERSION_TARGET=3.11
ENV NEXTFLOW_VERSION=23.10.1
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8
ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/opt/venv/bin:${PATH}"

RUN set -e && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        software-properties-common \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg && \
    \
    add-apt-repository -y universe && \
    add-apt-repository -y multiverse && \
    apt-get update && \
    \
    apt-get install -y --no-install-recommends \
        git \
        unzip \
        wget \
        build-essential \
        libssl-dev \
        zlib1g-dev \
        libbz2-dev \
        liblzma-dev \
        libcurl4-gnutls-dev \
        libncurses5-dev \
        libncursesw5-dev \
        libperl-dev \
        libreadline-dev \
        libsqlite3-dev \
        llvm \
        xz-utils \
        tk-dev \
        libffi-dev \
        bcftools \
        samtools \
        gnuplot && \
    \
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | tee /etc/apt/sources.list.d/google-cloud-sdk.list && \
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --yes --dearmor --batch --output /usr/share/keyrings/cloud.google.gpg && \
    apt-get update && \
    apt-get install -y --no-install-recommends google-cloud-sdk && \
    \
    add-apt-repository ppa:deadsnakes/ppa -y && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        "python${PYTHON_VERSION_TARGET}" \
        "python${PYTHON_VERSION_TARGET}-dev" \
        "python${PYTHON_VERSION_TARGET}-venv" \
        python3-pip && \
    update-alternatives --install /usr/bin/python3 python3 "/usr/bin/python${PYTHON_VERSION_TARGET}" 1 && \
    \
    python3 -m venv /opt/venv && \
    /opt/venv/bin/python3 -m pip install --no-cache-dir --upgrade pip setuptools wheel && \
    /opt/venv/bin/pip install --no-cache-dir \
        google-cloud-bigquery~=3.18.0 \
        pandas~=2.1.4 \
        numpy~=1.26.2 \
        scipy~=1.11.4 \
        google-cloud-storage~=2.14.0 \
        matplotlib~=3.8.0 \
        seaborn~=0.13.0 && \
    \
    cd /opt && \
    curl -fsSL "https://get.nextflow.io" | bash -s "v${NEXTFLOW_VERSION}" && \
    mv nextflow /usr/local/bin/nextflow && \
    cd / && \
    \
    apt-get purge -y --auto-remove build-essential software-properties-common gnupg && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /root/.cache && \
    find /etc/apt/sources.list.d/ -type f -name '*.list' -delete

WORKDIR /opt/analysis_workspace

COPY main.nf nextflow.config /opt/analysis_workspace/
COPY modules /opt/analysis_workspace/modules/

CMD ["nextflow", "info"]
