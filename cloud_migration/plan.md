# EC2 Migration Guide: Kafka + Generator + Connectors

**Goal:** Move the Kafka broker, event generator, and both Snowflake Kafka Connect workers off your Mac
and onto an EC2 instance so connector throughput — not local hardware or home-network bandwidth —
becomes the binding constraint. This unlocks the V3 vs V4 HP comparison that local Docker cannot
produce cleanly.

**Date authored:** April 2, 2026  
**Applies to:** `april_live_demo` project, current `docker-compose.yml`

---

## Table of Contents

1. [Overview](#1-overview)
2. [Infrastructure Impact Matrix](#2-infrastructure-impact-matrix)
3. [EC2 Provisioning](#3-ec2-provisioning)
4. [OS and Docker Setup](#4-os-and-docker-setup)
5. [Secrets and Credentials Transport](#5-secrets-and-credentials-transport)
6. [EC2 docker-compose Changes](#6-ec2-docker-compose-changes)
7. [Connector Config Tuning for Benchmarking](#7-connector-config-tuning-for-benchmarking)
8. [Producer Tuning for Higher Rates](#8-producer-tuning-for-higher-rates)
9. [Step-by-Step Migration Checklist](#9-step-by-step-migration-checklist)
10. [Verification](#10-verification)
11. [Benchmark Test Protocol](#11-benchmark-test-protocol)

---

## 1. Overview

### What moves to EC2


| Container                        | Current port (Mac) | EC2 port                   |
| -------------------------------- | ------------------ | -------------------------- |
| `payments-kafka`                 | `9092`             | `9092` (optional external) |
| `payments-kafka-init`            | — (one-shot)       | — (one-shot)               |
| `payments-kafka-connect` (V4 HP) | `8083`             | `8083`                     |
| `payments-kafka-connect-v3` (V3) | `8084`             | `8084`                     |
| `payments-generator`             | `8001`             | `8001`                     |


### What stays local (Snowflake-only, not affected)


| Container                                | Why it stays                                  |
| ---------------------------------------- | --------------------------------------------- |
| `app` (FastAPI backend + React frontend) | Reads Snowflake directly; no Kafka dependency |
| `curated_analytics` (Streamlit)          | Reads Snowflake directly                      |
| `fallback_ingest`                        | Writes to Snowflake directly                  |
| `dbt`                                    | Transforms within Snowflake                   |


### Why EC2 over alternatives

**EC2 (chosen):** Simplest lift of existing `docker-compose.yml`. Same tooling — `docker compose up`,
`docker logs`, `curl localhost:8083`. All five services run in the same Docker bridge network, so
container-to-container communication is unchanged (`kafka:29092`, etc.). Network path to Snowflake's
S3 staging buckets is in the same AWS backbone.

**SPCS (not chosen):** SPCS services receive inbound connections from Snowflake; they do not initiate
outbound connections to external Kafka brokers cleanly without an External Access Integration.
Adds significant setup complexity with no throughput benefit for this benchmark.

**MSK (not chosen):** Requires IAM permissions your environment may not have. Self-hosted Kafka on
EC2 is fully sufficient for single-broker benchmarking.

---

## 2. Infrastructure Impact Matrix

Every named component, what changes, and who owns the change.


| Component                        | Moves?  | Config change required                                                          | Owner                                       |
| -------------------------------- | ------- | ------------------------------------------------------------------------------- | ------------------------------------------- |
| `payments-kafka`                 | ✅ EC2   | Advertised listener, EBS volume path, JVM heap, network threads, socket buffers | EC2 `docker-compose.yml`                    |
| `payments-kafka-init`            | ✅ EC2   | None — uses internal `kafka:29092` already                                      | No change                                   |
| `payments-kafka-connect` (V4 HP) | ✅ EC2   | `tasks.max` tuning; secrets via `.env`                                          | `kafka-connect/shared.json` + EC2 `.env`    |
| `payments-kafka-connect-v3` (V3) | ✅ EC2   | `tasks.max`, `buffer.`* tuning; secrets via `.env`                              | `kafka-connect-v3/shared.json` + EC2 `.env` |
| `payments-generator`             | ✅ EC2   | Producer `batch.size`, `linger.ms`; higher `GENERATOR_RATE`                     | `generator/producer.py` + EC2 `.env`        |
| `app/backend`                    | ❌ Local | `GENERATOR_URL` env var → `http://<EC2-IP>:8001`                                | Local `.env`                                |
| `curated_analytics`              | ❌ Local | None                                                                            | —                                           |
| `fallback_ingest`                | ❌ Local | None                                                                            | —                                           |
| `dbt`                            | ❌ Local | None                                                                            | —                                           |
| Manual `curl` commands           | N/A     | Replace `localhost:8083` → `<EC2-IP>:8083`, `localhost:8084` → `<EC2-IP>:8084`  | Your terminal                               |


### Cross-boundary data flows after migration

```
Mac (local)                          EC2 instance
───────────────                      ─────────────────────────────────────────
  app/backend  ──GENERATOR_URL──────► generator :8001  (rate control, scenario API)
  your terminal ──curl──────────────► kafka-connect :8083  (connector management)
  your terminal ──curl──────────────► kafka-connect-v3 :8084  (connector management)
  your terminal ──kafka-cli──────────► kafka :9092  (lag checks, optional)

Both connectors ──S3 upload──────────────────────────────────► Snowflake
```

---

## 3. EC2 Provisioning

### 3.1 Instance type


| Option                       | vCPU | RAM    | Use case                                                       |
| ---------------------------- | ---- | ------ | -------------------------------------------------------------- |
| `r5.2xlarge` *(minimum)*     | 8    | 64 GB  | Fits all services; V3 JVM headroom limited                     |
| `r5.4xlarge` *(recommended)* | 16   | 128 GB | Comfortable headroom; push V3 `tasks.max=4` + V4 `tasks.max=8` |


Memory breakdown for `r5.4xlarge`:

- Kafka broker JVM: 6 GB heap (`-Xmx6g`)
- V4 HP Connector (Rust): ~2 GB RSS observed at 50K rps
- V3 Connector JVM (Confluent CP + Java Ingest SDK): 8–16 GB heap at `tasks.max=4`
- Generator (Python): ~500 MB
- OS + page cache (Kafka benefits heavily from page cache): 20+ GB
- **Total used: ~36–44 GB → 128 GB gives ample buffer**

### 3.2 AMI

Either of:

- **Amazon Linux 2023** (AL2023) — recommended, includes `dnf`, AWS-optimized kernel
- **Ubuntu 22.04 LTS** — familiar if you prefer `apt`

Commands below use Amazon Linux 2023 syntax. Ubuntu equivalents noted where they differ.

### 3.3 Region

Use the **same AWS region as your Snowflake account**. For most Business Critical accounts on AWS:
check `SHOW REGIONS` in Snowflake or look at the account URL (e.g., `xy12345.us-east-1` → `us-east-1`).

Running in the same region means connector S3 uploads stay on the AWS backbone (no public internet
egress, lower latency, no data transfer charges).

### 3.4 EBS volume

Attach a **second EBS volume** for Kafka data — do not use the root volume, which is typically
smaller and shared with the OS.


| Setting    | Value    | Rationale                                                                          |
| ---------- | -------- | ---------------------------------------------------------------------------------- |
| Type       | `gp3`    | Baseline 3,000 IOPS / 125 MB/s, provisionable to 16,000 IOPS                       |
| Size       | 200 GB   | 48 partitions × 500 MB retention × 2 topics = ~48 GB max; 200 GB gives replay room |
| IOPS       | 6,000    | At 100K rps × ~200 bytes = 20 MB/s writes; 6K IOPS handles segment rotation        |
| Throughput | 250 MB/s | Matches connector read peaks during large backlog drains                           |


Mount point: `/data/kafka`

### 3.5 Security Group inbound rules

**Restrict source to your Mac's public IP**, not `0.0.0.0/0`.


| Port | Protocol | Source  | Purpose                                                     |
| ---- | -------- | ------- | ----------------------------------------------------------- |
| 22   | TCP      | Your IP | SSH access                                                  |
| 8083 | TCP      | Your IP | V4 HP Connect REST API                                      |
| 8084 | TCP      | Your IP | V3 Connect REST API                                         |
| 8001 | TCP      | Your IP | Generator control API                                       |
| 9092 | TCP      | Your IP | Kafka (only needed for `kafka-consumer-groups.sh` from Mac) |


> **Note on port 9092:** If you only ever run `kafka-consumer-groups.sh` from inside the EC2 instance
> (via `docker exec`), port 9092 does not need to be open externally at all. The generator and both
> connectors use the internal Docker listener `kafka:29092` and are unaffected either way.

---

## 4. OS and Docker Setup

SSH into the instance as `ec2-user` (AL2023) or `ubuntu` (Ubuntu 22.04).

### 4.1 Install Docker Engine

**Amazon Linux 2023:**

```bash
sudo dnf update -y
sudo dnf install -y docker git
sudo systemctl enable --now docker
sudo usermod -aG docker ec2-user
# Log out and back in for group change to take effect
```

**Ubuntu 22.04:**

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo usermod -aG docker ubuntu
```

Install Docker Compose plugin (AL2023):

```bash
sudo dnf install -y docker-compose-plugin
docker compose version   # verify
```

### 4.2 Mount EBS volume

```bash
# Find the device name (usually /dev/xvdb or /dev/nvme1n1 on Nitro instances)
lsblk

# Format (only on first use — this destroys data)
sudo mkfs -t xfs /dev/nvme1n1

# Mount
sudo mkdir -p /data/kafka
sudo mount /dev/nvme1n1 /data/kafka

# Persist across reboots — add to /etc/fstab
echo "$(sudo blkid -s UUID -o value /dev/nvme1n1)  /data/kafka  xfs  defaults,noatime  0  2" | \
  sudo tee -a /etc/fstab

# Set permissions for Docker
sudo mkdir -p /data/kafka/logs
sudo chown -R 1000:1000 /data/kafka
```

> `**noatime**` disables access-time updates on every read, which matters for Kafka's high-frequency
> segment reads during consumer catch-up. On a busy topic it reduces write amplification noticeably.

### 4.3 Kernel tuning

Create `/etc/sysctl.d/99-kafka.conf`:

```
# Prevent JVM and Kafka from swapping under memory pressure
vm.swappiness = 1

# Large socket buffers for high-throughput producer/consumer connections
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 65536 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728

# Increase dirty page ratio — Kafka writes sequentially; OS can buffer more
vm.dirty_ratio = 80
vm.dirty_background_ratio = 5
```

Apply immediately:

```bash
sudo sysctl -p /etc/sysctl.d/99-kafka.conf
```

### 4.4 File descriptor limits

Append to `/etc/security/limits.conf`:

```
*    soft    nofile    100000
*    hard    nofile    100000
root soft    nofile    100000
root hard    nofile    100000
```

Configure Docker daemon to pass these through. Create or edit `/etc/docker/daemon.json`:

```json
{
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 100000,
      "Soft": 100000
    }
  }
}
```

Restart Docker after this change:

```bash
sudo systemctl restart docker
```

---

## 5. Secrets and Credentials Transport

The EC2 docker-compose needs the same three Snowflake secrets currently in your local `.env`:

- `SNOWFLAKE_URL`
- `SNOWFLAKE_USER`
- `SNOWFLAKE_PRIVATE_KEY`

### Option A: scp (simplest for a demo/benchmark environment)

```bash
# From your Mac — copy your existing .env to EC2
scp -i ~/.ssh/your-key.pem .env ec2-user@<EC2-IP>:~/april_live_demo/.env
```

### Option B: AWS SSM Parameter Store (recommended if you plan to run this long-term)

```bash
# Store each secret (run from Mac with appropriate AWS credentials)
aws ssm put-parameter \
  --name "/april_live_demo/SNOWFLAKE_URL" \
  --value "your-account.snowflakecomputing.com" \
  --type "SecureString"

aws ssm put-parameter \
  --name "/april_live_demo/SNOWFLAKE_USER" \
  --value "your_user" \
  --type "SecureString"

aws ssm put-parameter \
  --name "/april_live_demo/SNOWFLAKE_PRIVATE_KEY" \
  --value "$(cat path/to/private_key.p8)" \
  --type "SecureString"

# On EC2 — pull them into a .env file at startup
aws ssm get-parameter --name "/april_live_demo/SNOWFLAKE_URL" \
  --with-decryption --query Parameter.Value --output text >> .env
# Repeat for all three
```

### Local `.env` change (Mac-side only)

Add this one line to your **local** `.env` so `app/backend` can reach the generator on EC2:

```bash
GENERATOR_URL=http://<EC2-PUBLIC-IP>:8001
```

Then restart the local `app` container:

```bash
docker compose restart app
```

---

## 6. EC2 docker-compose Changes

The EC2 `docker-compose.yml` is a copy of the current file with five targeted changes.
Below is a complete annotated diff. Lines marked `# CHANGED` or `# ADDED` are the only
modifications — everything else is identical to the local version.

```yaml
services:
  kafka:
    image: apache/kafka:4.0.2
    container_name: payments-kafka
    ports:
      - "9092:9092"
    volumes:
      - /data/kafka/logs:/tmp/kraft-logs    # CHANGED: EBS mount instead of ./kafka-data
    environment:
      KAFKA_NODE_ID: 1
      KAFKA_PROCESS_ROLES: broker,controller
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@kafka:9093
      KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093,INTERNAL://0.0.0.0:29092
      # CHANGED: localhost → EC2 public DNS so external clients (Mac) can connect
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://<EC2_PUBLIC_DNS>:9092,INTERNAL://kafka:29092
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT,INTERNAL:PLAINTEXT
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
      KAFKA_LOG_DIRS: /tmp/kraft-logs
      CLUSTER_ID: MkU3OEVBNTcwNTJENDM2Qk    # keep same as local OR delete to auto-generate

      # --- Broker performance tuning (ADDED) ---
      # JVM heap: default 256m is the primary Mac-side throttle
      KAFKA_HEAP_OPTS: "-Xmx6g -Xms6g"
      # Network threads: handles incoming producer/consumer connections
      KAFKA_NUM_NETWORK_THREADS: "16"
      # I/O threads: handles disk reads/writes per broker
      KAFKA_NUM_IO_THREADS: "16"
      # Increase max queued requests before backpressure
      KAFKA_QUEUED_MAX_REQUESTS: "1000"
      # Socket buffer sizes: 100 KB → 1 MB for high-throughput producer connections
      KAFKA_SOCKET_SEND_BUFFER_BYTES: "1048576"
      KAFKA_SOCKET_RECEIVE_BUFFER_BYTES: "1048576"

      # Message size limits (unchanged from local)
      KAFKA_MESSAGE_MAX_BYTES: 10485760
      KAFKA_REPLICA_FETCH_MAX_BYTES: 52428800    # CHANGED: 10 MB → 50 MB
      KAFKA_SOCKET_REQUEST_MAX_BYTES: 10485760

      # Retention: extended for replay benchmark scenarios
      KAFKA_LOG_RETENTION_MS: "10800000"         # CHANGED: 1 hour → 3 hours
      KAFKA_LOG_RETENTION_BYTES: "524288000"     # CHANGED: 200 MB → 500 MB per partition
      KAFKA_LOG_SEGMENT_BYTES: "10485760"
      KAFKA_LOG_RETENTION_CHECK_INTERVAL_MS: "30000"

  kafka-init:
    # No changes needed — uses kafka:29092 internally
    image: apache/kafka:4.0.2
    container_name: payments-kafka-init
    depends_on:
      - kafka
    command:
      - /bin/sh
      - -c
      - |
        echo "Waiting for Kafka broker to be ready..."
        until /opt/kafka/bin/kafka-topics.sh \
            --bootstrap-server kafka:29092 --list > /dev/null 2>&1; do
          sleep 2
        done
        echo "Broker ready. Creating topics (48 partitions each)..."
        /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka:29092 \
          --create --if-not-exists \
          --topic payments.auth --partitions 48 --replication-factor 1
        /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka:29092 \
          --create --if-not-exists \
          --topic payments.auth.v3 --partitions 48 --replication-factor 1
        echo "Topics ready."
    restart: "no"

  kafka-connect:
    # No Dockerfile changes needed
    build:
      context: kafka-connect
      dockerfile: Dockerfile
    container_name: payments-kafka-connect
    ports:
      - "8083:8083"
    environment:
      CONNECT_BOOTSTRAP_SERVERS: "kafka:29092"    # unchanged — internal Docker network
      CONNECT_REST_ADVERTISED_HOST_NAME: "kafka-connect"
      CONNECT_REST_PORT: 8083
      CONNECT_GROUP_ID: "snowflake-connector-group"
      CONNECT_CONFIG_STORAGE_TOPIC: "_connect-configs"
      CONNECT_CONFIG_STORAGE_REPLICATION_FACTOR: "1"
      CONNECT_OFFSET_STORAGE_TOPIC: "_connect-offsets"
      CONNECT_OFFSET_STORAGE_REPLICATION_FACTOR: "1"
      CONNECT_STATUS_STORAGE_TOPIC: "_connect-status"
      CONNECT_STATUS_STORAGE_REPLICATION_FACTOR: "1"
      CONNECT_KEY_CONVERTER: "org.apache.kafka.connect.storage.StringConverter"
      CONNECT_VALUE_CONVERTER: "org.apache.kafka.connect.json.JsonConverter"
      CONNECT_VALUE_CONVERTER_SCHEMAS_ENABLE: "false"
      CONNECT_PLUGIN_PATH: "/usr/share/java,/usr/share/confluent-hub-components"
      SNOWFLAKE_URL: "${SNOWFLAKE_URL}"
      SNOWFLAKE_USER: "${SNOWFLAKE_USER}"
      SNOWFLAKE_PRIVATE_KEY: "${SNOWFLAKE_PRIVATE_KEY}"
      CONNECT_CONFIG_PROVIDERS: "env"
      CONNECT_CONFIG_PROVIDERS_ENV_CLASS: "org.apache.kafka.common.config.provider.EnvVarConfigProvider"
    depends_on:
      kafka-init:
        condition: service_completed_successfully

  kafka-connect-v3:
    build:
      context: kafka-connect-v3
      dockerfile: Dockerfile
    container_name: payments-kafka-connect-v3
    ports:
      - "8084:8083"
    environment:
      CONNECT_BOOTSTRAP_SERVERS: "kafka:29092"    # unchanged
      CONNECT_REST_ADVERTISED_HOST_NAME: "kafka-connect-v3"
      CONNECT_REST_PORT: 8083
      CONNECT_GROUP_ID: "snowflake-connector-v3-group"
      CONNECT_CONFIG_STORAGE_TOPIC: "_connect-v3-configs"
      CONNECT_CONFIG_STORAGE_REPLICATION_FACTOR: "1"
      CONNECT_OFFSET_STORAGE_TOPIC: "_connect-v3-offsets"
      CONNECT_OFFSET_STORAGE_REPLICATION_FACTOR: "1"
      CONNECT_STATUS_STORAGE_TOPIC: "_connect-v3-status"
      CONNECT_STATUS_STORAGE_REPLICATION_FACTOR: "1"
      CONNECT_KEY_CONVERTER: "org.apache.kafka.connect.storage.StringConverter"
      CONNECT_VALUE_CONVERTER: "org.apache.kafka.connect.json.JsonConverter"
      CONNECT_VALUE_CONVERTER_SCHEMAS_ENABLE: "false"
      CONNECT_PLUGIN_PATH: "/usr/share/java,/usr/share/confluent-hub-components"
      SNOWFLAKE_URL: "${SNOWFLAKE_URL}"
      SNOWFLAKE_USER: "${SNOWFLAKE_USER}"
      SNOWFLAKE_PRIVATE_KEY: "${SNOWFLAKE_PRIVATE_KEY}"
      CONNECT_CONFIG_PROVIDERS: "env"
      CONNECT_CONFIG_PROVIDERS_ENV_CLASS: "org.apache.kafka.common.config.provider.EnvVarConfigProvider"
    depends_on:
      kafka-init:
        condition: service_completed_successfully

  generator:
    build:
      context: generator
      dockerfile: Dockerfile
    container_name: payments-generator
    ports:
      - "8001:8000"
    environment:
      KAFKA_BOOTSTRAP_SERVERS: "kafka:29092"    # unchanged
      KAFKA_TOPIC: "payments.auth"
      GENERATOR_RATE: "100000"    # CHANGED: 50K → 100K rps to stress both connectors
      GENERATOR_ENV: "dev"
    depends_on:
      kafka-init:
        condition: service_completed_successfully
    command: ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

> `**CLUSTER_ID` note:** The hardcoded value `MkU3OEVBNTcwNTJENDM2Qk` is fine to reuse on EC2
> since you are starting with a clean EBS volume and fresh topic data. Alternatively, delete the
> `CLUSTER_ID` line entirely — Kafka will auto-generate a new one on first boot. Either approach
> works; do not copy the existing `kafka-data/` directory from Mac to EC2 (leave topics fresh).

---

## 7. Connector Config Tuning for Benchmarking

These changes go in the connector `shared.json` files before registering connectors on EC2.
Recommend keeping separate `shared.ec2.json` files so the local configs stay unchanged.

### 7.1 V4 HP (`kafka-connect/shared.json`)

```json
{
  "name": "auth-events-sink-v4",
  "config": {
    "connector.class": "com.snowflake.kafka.connector.SnowflakeStreamingSinkConnector",
    "tasks.max": "8",
    ...
  }
}
```

`tasks.max` increase from 4 → 8 means 8 consumer threads across 48 partitions (6 partitions/task).
Each task maps to one Rust worker process. The Rust runtime's internal worker pool (`num_workers: 12`
observed at `tasks.max=4`) will scale with available CPU.

### 7.2 V3 (`kafka-connect-v3/shared.json`)

```json
{
  "name": "auth-events-sink-v3",
  "config": {
    "connector.class": "com.snowflake.kafka.connector.SnowflakeSinkConnector",
    "tasks.max": "4",
    "buffer.flush.time": "10",
    "buffer.count.records": "50000",
    "buffer.size.bytes": "10485760",
    ...
  }
}
```

Changes from local defaults:


| Setting                | Local            | EC2 benchmark      |
| ---------------------- | ---------------- | ------------------ |
| `tasks.max`            | `1`              | `4`                |
| `buffer.count.records` | `10000`          | `50000`            |
| `buffer.size.bytes`    | `5242880` (5 MB) | `10485760` (10 MB) |


> **Important:** `tasks.max=4` on a 48-partition topic creates 4 Java Ingest SDK channels (12
> partitions each). Each channel holds its own JVM buffer. At `buffer.size.bytes=10MB × 4 tasks`,
> peak buffer usage is ~40 MB per connector, well within the `r5.4xlarge` headroom. With `tasks.max=1`,
> V3's throughput ceiling is artificially capped by single-channel serialization; this change is what
> lets you see where V3's *architectural* ceiling is, not its single-task ceiling.

---

## 8. Producer Tuning for Higher Rates

The generator's Kafka producer in `generator/producer.py` uses settings tuned for 50K rps on a Mac.
For EC2 at 100K+ rps, increase batch accumulation to reduce per-batch overhead:

```python
return Producer(
    {
        "bootstrap.servers": BOOTSTRAP_SERVERS,
        "compression.type": "zstd",
        "acks": "all",
        "linger.ms": 15,           # was 5 — accumulate larger batches
        "batch.size": 131072,      # was 16384 — 128 KB batches vs 16 KB
        "message.max.bytes": 10485760,
        "queue.buffering.max.messages": 500000,
    }
)
```

### Why these numbers

- `**batch.size: 131072**` — at 100K rps × ~230 bytes/event = 23 MB/s. With 16 KB batches, the
producer sends ~1,437 small requests/sec. With 128 KB batches, it sends ~180 larger requests/sec.
Fewer requests means less broker-side overhead and better zstd compression ratio (more context).
- `**linger.ms: 15**` — gives the producer 15 ms to fill a batch. At 100K rps with 128 KB batches,
a batch fills in ~5.5 ms anyway, so this is a ceiling not a floor. No meaningful latency impact
for a throughput benchmark.
- `**acks: "all"**` is kept — it ensures Kafka confirms persistence before the producer moves on,
giving accurate lag measurements. With `replication_factor=1` (single broker), `acks=all` and
`acks=1` are equivalent anyway.

---

## 9. Step-by-Step Migration Checklist

Work through these in order. Each step has a verification command.

### Phase 1: EC2 setup

```bash
# 1. Launch EC2 (r5.4xlarge, AL2023, 200 GB gp3 second volume)
#    Do this in AWS Console or via CLI

# 2. SSH in
ssh -i ~/.ssh/your-key.pem ec2-user@<EC2-IP>

# 3. Install Docker
sudo dnf update -y && sudo dnf install -y docker docker-compose-plugin git
sudo systemctl enable --now docker
sudo usermod -aG docker ec2-user
# VERIFY: logout, log back in, then:
docker run --rm hello-world

# 4. Kernel tuning
sudo tee /etc/sysctl.d/99-kafka.conf <<'EOF'
vm.swappiness = 1
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 65536 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
vm.dirty_ratio = 80
vm.dirty_background_ratio = 5
EOF
sudo sysctl -p /etc/sysctl.d/99-kafka.conf
# VERIFY:
sysctl vm.swappiness   # should print vm.swappiness = 1

# 5. File descriptor limits
echo -e "*    soft    nofile    100000\n*    hard    nofile    100000" | sudo tee -a /etc/security/limits.conf
sudo tee /etc/docker/daemon.json <<'EOF'
{"default-ulimits": {"nofile": {"Name": "nofile", "Hard": 100000, "Soft": 100000}}}
EOF
sudo systemctl restart docker

# 6. Mount EBS
lsblk   # identify second disk, e.g. nvme1n1
sudo mkfs -t xfs /dev/nvme1n1
sudo mkdir -p /data/kafka/logs
sudo mount /dev/nvme1n1 /data/kafka
echo "$(sudo blkid -s UUID -o value /dev/nvme1n1)  /data/kafka  xfs  defaults,noatime  0  2" | sudo tee -a /etc/fstab
sudo chown -R 1000:1000 /data/kafka
# VERIFY:
df -h /data/kafka   # should show ~186 GB available on /data/kafka
```

### Phase 2: Project files

```bash
# 7. Clone or rsync the project (from your Mac)
# Option A — git clone
git clone <your-repo-url> ~/april_live_demo

# Option B — rsync (excludes kafka-data and node_modules)
rsync -av --exclude='kafka-data/' --exclude='node_modules/' \
  /Users/slafell/Documents/_Work_Projects/april_live_demo/ \
  ec2-user@<EC2-IP>:~/april_live_demo/

# 8. Copy secrets
scp -i ~/.ssh/your-key.pem .env ec2-user@<EC2-IP>:~/april_live_demo/.env

# 9. Edit docker-compose.yml on EC2
# Replace KAFKA_ADVERTISED_LISTENERS localhost with EC2 public DNS
# Replace ./kafka-data with /data/kafka/logs
# Add KAFKA_HEAP_OPTS and other tuning settings (see Section 6)
cd ~/april_live_demo
# Use your preferred editor (vim, nano, etc.)
```

### Phase 3: Start services in order

```bash
# 10. Start Kafka broker first
docker compose up -d kafka
# VERIFY — wait ~10s, then:
docker logs payments-kafka 2>&1 | grep -i "started\|ERROR" | tail -5

# 11. Run topic init
docker compose up kafka-init
# VERIFY:
docker exec payments-kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 --list
# Expected output:
#   payments.auth
#   payments.auth.v3

# 12. Start connectors
docker compose up -d kafka-connect kafka-connect-v3
# VERIFY — wait 30s for Connect workers to initialize:
curl -s http://localhost:8083/connectors | jq .   # should return []
curl -s http://localhost:8084/connectors | jq .   # should return []

# 13. Register V4 HP connector
curl -s -X POST http://localhost:8083/connectors \
  -H "Content-Type: application/json" \
  -d @kafka-connect/shared.json | jq .

# 14. Register V3 connector
curl -s -X POST http://localhost:8084/connectors \
  -H "Content-Type: application/json" \
  -d @kafka-connect-v3/shared.json | jq .

# VERIFY connector states:
curl -s http://localhost:8083/connectors/auth-events-sink-v4/status | jq .connector.state
curl -s http://localhost:8084/connectors/auth-events-sink-v3/status | jq .connector.state
# Both should return "RUNNING"

# 15. Start generator
docker compose up -d generator
# VERIFY:
curl -s http://localhost:8001/status | jq .
# Expected: { "scenario": "baseline", "events_per_sec": 100000, ... }

# 16. Update local .env on Mac
echo "GENERATOR_URL=http://<EC2-IP>:8001" >> /Users/slafell/Documents/_Work_Projects/april_live_demo/.env
docker compose restart app   # pick up new GENERATOR_URL
```

---

## 10. Verification

Run these from EC2 to confirm everything is healthy after migration.

### Kafka consumer lag

```bash
# V4 HP lag (should be small and stable, CONSUMER-ID active)
docker exec payments-kafka /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 \
  --describe --group connect-auth-events-sink-v4

# V3 lag (should be small across all partitions, CONSUMER-ID active)
docker exec payments-kafka /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 \
  --describe --group connect-auth-events-sink-v3
```

Healthy signals: `CONSUMER-ID` shows active UUID, `LAG` is small relative to `LOG-END-OFFSET`.
Unhealthy signals: `CONSUMER-ID` = `-`, `LAG` growing on every check (not just absolute size).

### Snowflake row counts

```sql
-- V4 HP rows landed (should be growing)
SELECT COUNT(*) FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW;

-- V3 rows landed (should be growing)
SELECT COUNT(*) FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW_V3;

-- Ingest rate for both (last 5 minutes)
SELECT
    connector_version,
    COUNT(*) AS rows_ingested,
    MIN(INGESTED_AT) AS earliest,
    MAX(INGESTED_AT) AS latest
FROM (
    SELECT 'V4_HP' AS connector_version, INGESTED_AT FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW
    WHERE INGESTED_AT > DATEADD(MINUTE, -5, CURRENT_TIMESTAMP)
    UNION ALL
    SELECT 'V3', RECORD_METADATA:CreateTime::TIMESTAMP_NTZ
    FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW_V3
    WHERE RECORD_METADATA:CreateTime::TIMESTAMP_NTZ > DATEADD(MINUTE, -5, CURRENT_TIMESTAMP)
)
GROUP BY 1;
```

### Generator throughput

```bash
# From EC2
curl -s http://localhost:8001/status | jq '{rate: .events_per_sec, total: .total_events, uptime: .uptime_sec}'

# From Mac (after updating GENERATOR_URL)
curl -s http://<EC2-IP>:8001/status | jq .
```

### Container resource usage

```bash
# Live stats — watch memory and CPU per container
docker stats --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}"
```

Key things to watch:

- `payments-kafka`: Memory should stay well below `KAFKA_HEAP_OPTS` max; CPU spikes indicate broker saturation
- `payments-kafka-connect-v3`: JVM heap growing toward limit indicates V3 being overwhelmed
- `payments-kafka-connect`: Rust RSS should stay relatively flat even under load

---

## 11. Benchmark Test Protocol

Run each test with **one connector at a time** unless explicitly doing a head-to-head. Two connectors
sharing the generator output cuts each connector's input in half.

### Test 1: Throughput ceiling (primary comparison)

**Goal:** Find the maximum sustained rate each connector can handle without growing lag.

```bash
# Start with 100K rps
curl -s -X POST http://localhost:8001/rate \
  -H "Content-Type: application/json" \
  -d '{"events_per_sec": 100000}'

# Monitor lag every 30 seconds for 10 minutes
watch -n 30 "docker exec payments-kafka /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 \
  --describe --group connect-auth-events-sink-v4 2>/dev/null | tail -3"
```

If lag is stable → increase rate by 25K. If lag is growing → that rate exceeds the connector ceiling.
Record the rate at which lag first starts growing.

**Expected outcome:**

- V4 HP ceiling: 150K–250K rps (12 Rust workers, async S3 uploads)
- V3 ceiling with `tasks.max=4`: 40K–80K rps (JVM GC pauses become visible above this range)

### Test 2: Cold-start backlog drain

**Goal:** Measure how fast each connector drains a large existing backlog.

```bash
# 1. Stop the connector (not delete — just stop the task)
curl -X PUT http://localhost:8083/connectors/auth-events-sink-v4/pause

# 2. Let the generator run for 5 minutes at 100K rps to build a ~30M record backlog
sleep 300

# 3. Check lag size
docker exec payments-kafka /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 \
  --describe --group connect-auth-events-sink-v4

# 4. Resume connector and time the drain
time curl -X PUT http://localhost:8083/connectors/auth-events-sink-v4/resume

# 5. Poll until lag returns to <500K
while true; do
  LAG=$(docker exec payments-kafka /opt/kafka/bin/kafka-consumer-groups.sh \
    --bootstrap-server localhost:9092 \
    --describe --group connect-auth-events-sink-v4 2>/dev/null | \
    awk 'NR>1 {sum += $6} END {print sum}')
  echo "$(date): lag=$LAG"
  [[ $LAG -lt 500000 ]] && break
  sleep 10
done
```

**Expected outcome:** V4 HP drains faster due to async Rust workers. V3 drain rate is bounded by
single-threaded Java channel serialization per task and GC pauses during high-throughput ingest.

### Test 3: Partition scaling

**Goal:** Show how each connector's throughput scales as partition count increases.

Run the same throughput test at:

- 12 partitions (reduce with `kafka-topics.sh --alter` — note: Kafka only allows increasing, not decreasing)
- 24 partitions
- 48 partitions

Since Kafka only increases partition count, run these tests in order: 12 → 24 → 48 by creating new
test topics.

**Expected outcome:** V4 HP throughput scales nearly linearly with partition count (Rust worker per
task, async within each). V3 throughput increases more slowly because each added Java channel object
adds JVM GC pressure.

### Test 4: Memory and GC profiling

**Goal:** Observe JVM heap behavior in V3 vs Rust RSS in V4 under sustained load.

```bash
# Terminal 1: Watch container memory continuously
watch -n 5 "docker stats --no-stream --format \
  'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' | \
  grep -E 'kafka-connect|CONTAINER'"

# Terminal 2: Check V3 JVM heap specifically
watch -n 10 "docker exec payments-kafka-connect-v3 \
  jcmd 1 GC.heap_info 2>/dev/null | grep -A2 'heap'"
```

**Signatures of V3 GC pressure:**

- Kafka consumer lag spikes every 60–120 seconds then partially recovers (GC pause signature)
- JVM heap climbing toward the container memory limit between spikes
- "Commit of offsets timed out" WARN lines in V3 logs

**Signatures of V4 HP health:**

- Flat RSS memory (Rust does not garbage collect)
- Queue depth remaining at 0 in logs
- Monotonically increasing Snowflake row count with no gaps

### Recording results

For each test, record:

- Generator rate (rps)
- Connector lag (stable / growing / draining) and direction
- Peak memory per container (`docker stats`)
- Time to drain backlog (Test 2)
- Snowflake row count delta per minute (from the ingest rate query in Section 10)

