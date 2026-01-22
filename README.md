# Kafka KRaft (no ZooKeeper) with SASL/PLAIN + SCRAM + Kafka UI

This repo provides a one-command launcher (`./kafka-start.sh`) that brings up Kafka in KRaft mode with:
- SASL/PLAIN for internal and external plaintext access
- SASL_SSL + SCRAM for encrypted access (optional to verify certs on clients)
- Kafka UI (optional)
- A generated `.env`, TLS material, and a ready-to-run compose file

## Requirements
- Docker + docker compose
- bash
- openssl (for TLS generation)
- python3 or uuidgen/xxd (for CLUSTER_ID generation; the script has fallbacks)

## Quick start (single broker)
```bash
git clone https://github.com/sci-ndp/kafka-kraft.git
cd kafka-kraft

# Local only
./kafka-start.sh --generate-passwords

# If clients connect from another machine, set the advertised host/IP
./kafka-start.sh --generate-passwords -H 10.244.2.218
```

Check status/logs:
```bash
docker compose -f docker-compose.generated.yml ps
# logs
docker compose -f docker-compose.generated.yml logs -f
```

Stop:
```bash
./kafka-stop.sh
```

## What the script creates
- `.env` with all settings (gitignored)
- `.kafka-credentials` with generated passwords (chmod 600)
- `docker-compose.generated.yml` (the file the script runs)
- `certs/` with `broker.p12`, `truststore.p12`, `ca.crt`
- `data/kafka` (single broker) or `data/broker-*` (multi broker)

## Configuration options (script flags)
Common flags:
- `-b, --brokers 1|3` start single broker or 3-broker KRaft quorum
- `-H, --host <host-or-ip>` advertised address clients will use
- `-u, --user <name>` admin user (PLAIN)
- `-p, --password <pass>` admin password (PLAIN)
- `-c, --client-user <name>` client user (PLAIN)
- `-C, --client-pass <pass>` client password (PLAIN)
- `--generate-passwords` auto-generate passwords
- `--external-port <port>` external SASL_PLAINTEXT port (single broker only)
- `--secure-port <port>` external SASL_SSL port (single broker only)
- `--no-ui` disable Kafka UI
- `--ui-port <port>` UI port
- `--force-certs` regenerate self-signed certs even if they exist
- `--foreground` run in foreground (default is detached)

## Operation modes (with examples)

### 1) Single broker (default)
- Ports: `9092` (SASL_PLAINTEXT), `9094` (SASL_SSL)
- Data dir: `data/kafka`

```bash
# Local only
./kafka-start.sh --generate-passwords

# Remote clients connect to this IP/DNS
./kafka-start.sh --generate-passwords -H 10.244.2.218
```

### 2) Three brokers (KRaft quorum)
- Ports:
  - broker-1: `19092` (plain), `19094` (ssl)
  - broker-2: `29092` (plain), `29094` (ssl)
  - broker-3: `39092` (plain), `39094` (ssl)
- Data dirs: `data/broker-1`, `data/broker-2`, `data/broker-3`

```bash
./kafka-start.sh -b 3 --generate-passwords -H 10.244.2.218

# kcat example (plain)
kcat -b 10.244.2.218:19092,10.244.2.218:29092,10.244.2.218:39092 \
  -X security.protocol=SASL_PLAINTEXT \
  -X sasl.mechanism=PLAIN \
  -X sasl.username=admin \
  -X sasl.password='<admin-pass>' \
  -L
```

### 3) UI on/off
```bash
# Disable UI
./kafka-start.sh --generate-passwords --no-ui

# Custom UI port
./kafka-start.sh --generate-passwords --ui-port 8081
```

### 4) Foreground vs detached
```bash
# Run in foreground (CTRL+C stops)
./kafka-start.sh --generate-passwords --foreground
```

### 5) TLS and auth modes (SASL_PLAINTEXT vs SASL_SSL)
You have two ways to connect externally:

**A) SASL_PLAINTEXT (no certs needed)**
```bash
kcat -b 10.244.2.218:9092 \
  -X security.protocol=SASL_PLAINTEXT \
  -X sasl.mechanism=PLAIN \
  -X sasl.username=admin \
  -X sasl.password='<admin-pass>' \
  -L
```

**B) SASL_SSL + SCRAM (encrypted)**
- If you want to verify certs, point at `certs/ca.crt`.
- If you want to skip verification (convenient for dev), disable it on the client.

Verify certs:
```bash
kcat -b 10.244.2.218:9094 \
  -X security.protocol=SASL_SSL \
  -X sasl.mechanism=SCRAM-SHA-512 \
  -X sasl.username='scram-admin' \
  -X sasl.password='<admin-pass>' \
  -X ssl.ca.location=/full/path/to/certs/ca.crt \
  -X ssl.endpoint.identification.algorithm=none \
  -L
```

Skip verification (still encrypted, but not authenticated):
```bash
kcat -b 10.244.2.218:9094 \
  -X security.protocol=SASL_SSL \
  -X sasl.mechanism=SCRAM-SHA-512 \
  -X sasl.username='scram-admin' \
  -X sasl.password='<admin-pass>' \
  -X enable.ssl.certificate.verification=false \
  -X ssl.endpoint.identification.algorithm=none \
  -L
```

### 6) Using your own TLS certs
If you already have `broker.p12` and `truststore.p12`, place them in `certs/` (or symlink `certs/` to a secure external directory). The script uses whatever is present unless you pass `--force-certs`.

## Users and auth

### PLAIN users (SASL_PLAINTEXT)
PLAIN users are defined in the broker JAAS config, so update `.env` and recreate the container:
```bash
# Edit .env, then
docker compose -f docker-compose.generated.yml up -d --force-recreate
```

### SCRAM users (SASL_SSL)
SCRAM users can be added without restart:
```bash
# Load admin creds from .env
set -a; source .env; set +a

./scripts/add_scram_user.sh new-user new-password
```

The `user-setup` container already creates `scram-admin` and `scram-client` on startup.

## Useful files
- `.env` - runtime settings used by compose
- `.kafka-credentials` - generated passwords and examples
- `docker-compose.generated.yml` - actual stack definition

## Smoke test
```bash
./scripts/test_stack.sh
```

## Troubleshooting
- If clients get `localhost` in metadata, you must set `-H <host-or-ip>` and restart.
- If permissions errors occur on `data/` or `certs/`, your filesystem may block chmod. Ensure the container user can read `certs/*.p12` and write to the data directory.
- If you do not want TLS at all, just use the 9092 listener (SASL_PLAINTEXT).

## Notes
- Single broker ports: `9092` (plain) and `9094` (ssl)
- Multi broker ports: `19092/19094`, `29092/29094`, `39092/39094`
- Internal/controller ports are not exposed
