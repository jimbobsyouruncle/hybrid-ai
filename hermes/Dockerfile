FROM python:3.11-slim

# Install system dependencies
# Add retry flags and quiet output to prevent mirror timeouts
RUN apt-get update -o Acquire::Retries=5 && \
    apt-get install -y --no-install-recommends \
        git \
        curl \
        build-essential \
        libxi6 && \
    rm -rf /var/lib/apt/lists/*

# Install Hermes Agent CLI system-wide
RUN curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash

# Clone and build Hermes WebUI
WORKDIR /app
RUN git clone https://github.com/nesquena/hermes-webui.git .
RUN pip install --no-cache-dir -r requirements.txt

EXPOSE 8501 8642

# Launch gateway daemon in background and WebUI in foreground
CMD ["bash", "-c", "source ~/.bashrc && hermes gateway & python3 bootstrap.py --port 8501 --host 0.0.0.0"]
