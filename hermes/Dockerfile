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

# Dedicated non-root service account. Created after the install and WORKDIR/pip
# steps, which run as root at build time; the image then runs as this uid.
# Defaults match the compose `build.args`, so a build with no args still gets a
# valid non-root uid.
ARG HYBRID_AI_UID=10001
ARG HYBRID_AI_GID=10001
RUN groupadd --gid "${HYBRID_AI_GID}" hermes && \
    useradd --uid "${HYBRID_AI_UID}" --gid "${HYBRID_AI_GID}" \
        --home-dir /root --no-create-home --shell /usr/sbin/nologin hermes && \
    chown -R "${HYBRID_AI_UID}:${HYBRID_AI_GID}" /root /app

# HOME stays /root. Saved state under hermes_data/ holds absolute /root/...
# paths and the compose volume paths are unchanged, so this must not move.
ENV HOME=/root
# The installer publishes the `hermes` launcher into $HOME/.local/bin. Put it on
# PATH from the image environment so CMD does not need to source ~/.bashrc.
ENV PATH="/root/.local/bin:${PATH}"

EXPOSE 8501 8642

USER ${HYBRID_AI_UID}:${HYBRID_AI_GID}

# Launch gateway daemon in background and WebUI in foreground
CMD ["bash", "-c", "hermes gateway & python3 bootstrap.py --port 8501 --host 0.0.0.0"]
