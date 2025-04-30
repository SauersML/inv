# Dockerfile for AoU H1/H2 Association Python Environment

# Use a standard Python base image
FROM python:3.10.13-slim

# Set working directory
WORKDIR /app

# Install necessary Python libraries using pinned versions
RUN pip install --no-cache-dir \
    google-cloud-bigquery==3.11.4 \
    pandas==1.5.3 \
    scipy==1.10.1 \
    numpy==1.23.5 \
    google-cloud-storage==2.7.0 # May be needed by BQ client or for direct GCS interaction if added later

# Copy the Python scripts from the bin directory into the container
COPY bin/ /app/bin/

# Make scripts executable
RUN chmod +x /app/bin/*.py

# Set Python path
ENV PYTHONPATH=/app/bin:$PYTHONPATH
