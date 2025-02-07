FROM debian:bullseye-slim
RUN apt-get update && apt-get install -y iperf3 postgresql-client && rm -rf /var/lib/apt/lists/*
CMD [ "sleep", "infinity" ]
