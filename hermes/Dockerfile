FROM python:3.11-slim

# Install system dependencies
RUN apt-get update && apt-get install -y \
    git \
    curl \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Install Hermes Agent CLI system-wide
RUN curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash

# Clone and build Hermes WebUI
WORKDIR /app
RUN git clone https://github.com/nesquena/hermes-webui.git .
RUN pip install --no-cache-dir -r requirements.txt

EXPOSE 8501 8642

# Launch gateway daemon in background and WebUI in foreground
CMD ["bash", "-c", "source ~/.bashrc && hermes gateway & python3 bootstrap.py --port 8501 --host 0.0.0.0"]
