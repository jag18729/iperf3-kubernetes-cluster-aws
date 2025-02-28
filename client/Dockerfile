FROM debian:bullseye-slim

# Install required packages
RUN apt-get update && \
    apt-get install -y \
    iperf3 \
    postgresql-client \
    jq \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Set default command
CMD [ "sleep", "infinity" ]
