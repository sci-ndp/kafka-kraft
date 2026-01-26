#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Default values
BROKERS=1
UI=true
ADMIN_USER="admin"
ADMIN_PASSWORD=""
CLIENT_USER="client"
CLIENT_PASSWORD=""
HOST="localhost"
SSL_PASSWORD=""
DETACH=true
FORCE_CERTS=false
UI_PORT=8080
EXTERNAL_PORT=9092
SECURE_PORT=9094

usage() {
    cat << EOF
${GREEN}Kafka KRaft Cluster Launcher${NC}

Usage: $0 [OPTIONS]

${YELLOW}Options:${NC}
  -b, --brokers NUM       Number of brokers (1 or 3, default: 1)
  -u, --user USERNAME     Admin username (default: admin)
  -p, --password PASS     Admin password (required, or use --generate-passwords)
  -c, --client-user USER  Client username (default: client)
  -C, --client-pass PASS  Client password (uses admin password if not set)
  -H, --host HOSTNAME     External hostname/IP for clients (default: localhost)
  --no-ui                 Disable Kafka UI
  --ui-port PORT          Kafka UI port (default: 8080)
  --external-port PORT    External Kafka port (default: 9092)
  --secure-port PORT      Secure SSL port (default: 9094)
  --ssl-password PASS     SSL keystore password (auto-generated if not set)
  --generate-passwords    Auto-generate secure passwords
  --force-certs           Regenerate SSL certificates even if they exist
  --foreground            Run in foreground (don't detach)
  -h, --help              Show this help message

${YELLOW}Examples:${NC}
  # Quick start with auto-generated passwords
  $0 --generate-passwords

  # Single broker with custom credentials
  $0 -u admin -p MySecretPass123

  # 3-broker cluster with UI disabled
  $0 -b 3 -u admin -p MyPass --no-ui

  # Production setup with custom host
  $0 -b 3 -H kafka.example.com -u admin -p SecurePass --generate-passwords

${YELLOW}After starting:${NC}
  - Kafka UI:       http://localhost:${UI_PORT} (if enabled)
  - Kafka (plain):  ${HOST}:${EXTERNAL_PORT} (SASL_PLAINTEXT)
  - Kafka (secure): ${HOST}:${SECURE_PORT} (SASL_SSL)

${YELLOW}Credentials file:${NC}
  After startup, credentials are saved to: .kafka-credentials
EOF
    exit 0
}

log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

generate_password() {
    # Generate a 16-character alphanumeric password
    if command -v openssl &> /dev/null; then
        openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 16
    else
        cat /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | head -c 16
    fi
}

generate_cluster_id() {
    # Generate a valid Kafka cluster ID (base64-encoded UUID, 22 chars, no padding)
    if command -v python3 &> /dev/null; then
        python3 - <<'PY'
import base64, uuid
print(base64.urlsafe_b64encode(uuid.uuid4().bytes).decode().rstrip("="))
PY
    elif command -v uuidgen &> /dev/null && command -v xxd &> /dev/null && command -v base64 &> /dev/null; then
        uuidgen | tr -d '-' | xxd -r -p | base64 | tr -d '=' | tr '+/' '-_'
    elif command -v openssl &> /dev/null; then
        openssl rand -base64 16 | tr -d '=' | tr '+/' '-_' | tr -d '\n'
    else
        echo "kp7Rzc7oT4GtsqDuqo21Wg"
    fi
}

resolve_certs_dir() {
    local cert_dir="$CERTS_DIR"
    if [[ -L "$cert_dir" ]]; then
        cert_dir="$(cd "$cert_dir" 2>/dev/null && pwd || echo "$CERTS_DIR")"
    fi
    echo "$cert_dir"
}

ensure_cert_permissions() {
    local cert_dir
    cert_dir="$(resolve_certs_dir)"
    if [[ -d "$cert_dir" ]]; then
        if ! chmod 755 "$cert_dir"; then
            warn "Unable to chmod certs directory ($cert_dir); container may not read keystores"
        fi
        if [[ -f "$cert_dir/broker.p12" ]] && ! chmod 644 "$cert_dir/broker.p12"; then
            warn "Unable to chmod $cert_dir/broker.p12; container may not read keystore"
        fi
        if [[ -f "$cert_dir/truststore.p12" ]] && ! chmod 644 "$cert_dir/truststore.p12"; then
            warn "Unable to chmod $cert_dir/truststore.p12; container may not read truststore"
        fi
    fi
}

prepare_data_dirs() {
    local dirs=()
    if [[ "$BROKERS" == "1" ]]; then
        dirs+=("$SCRIPT_DIR/data/kafka")
    else
        dirs+=("$SCRIPT_DIR/data/broker-1" "$SCRIPT_DIR/data/broker-2" "$SCRIPT_DIR/data/broker-3")
    fi
    for dir in "${dirs[@]}"; do
        mkdir -p "$dir"
        if ! chmod -R a+rwX "$dir"; then
            warn "Unable to chmod data directory ($dir); broker may not be able to write"
        fi
    done
}

# Parse arguments
GENERATE_PASSWORDS=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -b|--brokers)
            BROKERS="$2"
            shift 2
            ;;
        -u|--user)
            ADMIN_USER="$2"
            shift 2
            ;;
        -p|--password)
            ADMIN_PASSWORD="$2"
            shift 2
            ;;
        -c|--client-user)
            CLIENT_USER="$2"
            shift 2
            ;;
        -C|--client-pass)
            CLIENT_PASSWORD="$2"
            shift 2
            ;;
        -H|--host)
            HOST="$2"
            shift 2
            ;;
        --no-ui)
            UI=false
            shift
            ;;
        --ui-port)
            UI_PORT="$2"
            shift 2
            ;;
        --external-port)
            EXTERNAL_PORT="$2"
            shift 2
            ;;
        --secure-port)
            SECURE_PORT="$2"
            shift 2
            ;;
        --ssl-password)
            SSL_PASSWORD="$2"
            shift 2
            ;;
        --generate-passwords)
            GENERATE_PASSWORDS=true
            shift
            ;;
        --force-certs)
            FORCE_CERTS=true
            shift
            ;;
        --foreground)
            DETACH=false
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            error "Unknown option: $1\nUse --help for usage information."
            ;;
    esac
done

# Validate brokers
if [[ "$BROKERS" != "1" && "$BROKERS" != "3" ]]; then
    error "Number of brokers must be 1 or 3"
fi

# Handle password generation
if [[ "$GENERATE_PASSWORDS" == "true" ]]; then
    if [[ -z "$ADMIN_PASSWORD" ]]; then
        ADMIN_PASSWORD=$(generate_password)
        log "Generated admin password"
    fi
    if [[ -z "$CLIENT_PASSWORD" ]]; then
        CLIENT_PASSWORD=$(generate_password)
        log "Generated client password"
    fi
    if [[ -z "$SSL_PASSWORD" ]]; then
        SSL_PASSWORD=$(generate_password)
        log "Generated SSL password"
    fi
fi

# Validate required password
if [[ -z "$ADMIN_PASSWORD" ]]; then
    error "Admin password is required. Use -p/--password or --generate-passwords"
fi

# Set defaults if not provided
if [[ -z "$CLIENT_PASSWORD" ]]; then
    CLIENT_PASSWORD="$ADMIN_PASSWORD"
fi

if [[ -z "$SSL_PASSWORD" ]]; then
    SSL_PASSWORD=$(generate_password)
fi

CLUSTER_ID="${CLUSTER_ID:-$(generate_cluster_id)}"

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   Kafka KRaft Cluster Launcher${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
log "Configuration:"
echo "  - Brokers:        $BROKERS"
echo "  - UI:             $UI"
echo "  - Host:           $HOST"
echo "  - Admin User:     $ADMIN_USER"
echo "  - Client User:    $CLIENT_USER"
echo "  - Cluster ID:     $CLUSTER_ID"
echo ""

# Check for Docker or Podman
COMPOSE_CMD=""
if command -v docker &> /dev/null && docker compose version &> /dev/null; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose &> /dev/null; then
    COMPOSE_CMD="docker-compose"
elif command -v podman &> /dev/null && podman compose version &> /dev/null; then
    COMPOSE_CMD="podman compose"
else
    error "Docker Compose or Podman Compose is required but not found"
fi

log "Using: $COMPOSE_CMD"

# Generate certificates if needed
CERTS_DIR="$SCRIPT_DIR/certs"
if [[ ! -f "$CERTS_DIR/broker.p12" ]] || [[ "$FORCE_CERTS" == "true" ]]; then
    log "Generating SSL certificates..."

    # Create certs directory (remove symlink if exists)
    if [[ -L "$CERTS_DIR" ]]; then
        rm "$CERTS_DIR"
    fi
    mkdir -p "$CERTS_DIR"

    # Generate CA key and certificate
    openssl genrsa -out "$CERTS_DIR/ca.key" 4096 2>/dev/null
    openssl req -new -x509 -days 3650 -key "$CERTS_DIR/ca.key" \
        -out "$CERTS_DIR/ca.crt" -subj "/CN=kafka-ca" 2>/dev/null

    # Generate broker key and CSR
    openssl genrsa -out "$CERTS_DIR/broker.key" 4096 2>/dev/null

    # Create SAN config for the certificate
    cat > "$CERTS_DIR/san.cnf" << SANEOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = broker

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = broker
DNS.2 = broker-1
DNS.3 = broker-2
DNS.4 = broker-3
DNS.5 = localhost
DNS.6 = $HOST
IP.1 = 127.0.0.1
SANEOF

    openssl req -new -key "$CERTS_DIR/broker.key" \
        -out "$CERTS_DIR/broker.csr" \
        -config "$CERTS_DIR/san.cnf" 2>/dev/null

    # Sign the broker certificate
    openssl x509 -req -days 3650 \
        -in "$CERTS_DIR/broker.csr" \
        -CA "$CERTS_DIR/ca.crt" \
        -CAkey "$CERTS_DIR/ca.key" \
        -CAcreateserial \
        -out "$CERTS_DIR/broker.crt" \
        -extensions v3_req \
        -extfile "$CERTS_DIR/san.cnf" 2>/dev/null

    # Create PKCS12 keystore
    openssl pkcs12 -export \
        -in "$CERTS_DIR/broker.crt" \
        -inkey "$CERTS_DIR/broker.key" \
        -out "$CERTS_DIR/broker.p12" \
        -name broker \
        -password "pass:$SSL_PASSWORD" 2>/dev/null

    # Create truststore
    openssl pkcs12 -export \
        -in "$CERTS_DIR/ca.crt" \
        -nokeys \
        -out "$CERTS_DIR/truststore.p12" \
        -name ca \
        -password "pass:$SSL_PASSWORD" 2>/dev/null

    # Cleanup temp file
    rm -f "$CERTS_DIR/san.cnf"

    success "SSL certificates generated"
else
    success "SSL certificates already exist"
fi
ensure_cert_permissions

# Create .env file
log "Creating environment configuration..."
cat > "$SCRIPT_DIR/.env" << EOF
# Generated by kafka-start.sh on $(date)
HOST_IP=$HOST
CLUSTER_ID=$CLUSTER_ID

# SASL/PLAIN users
KAFKA_ADMIN_USER=$ADMIN_USER
KAFKA_ADMIN_PASSWORD=$ADMIN_PASSWORD
KAFKA_CLIENT_USER=$CLIENT_USER
KAFKA_CLIENT_PASSWORD=$CLIENT_PASSWORD

# SCRAM users (for SASL_SSL listener)
SCRAM_ADMIN_USER=scram-$ADMIN_USER
SCRAM_ADMIN_PASSWORD=$ADMIN_PASSWORD
SCRAM_CLIENT_USER=scram-$CLIENT_USER
SCRAM_CLIENT_PASSWORD=$CLIENT_PASSWORD

# TLS keystore/truststore password
SSL_STORE_PASSWORD=$SSL_PASSWORD

# UI settings
UI_PORT=$UI_PORT

# Port settings
EXTERNAL_PORT=$EXTERNAL_PORT
SECURE_PORT=$SECURE_PORT
EOF

success "Environment file created"

# Save credentials to a file for user reference
cat > "$SCRIPT_DIR/.kafka-credentials" << EOF
# Kafka Credentials - Generated $(date)
# Keep this file secure!

Cluster ID: $CLUSTER_ID
Host: $HOST

=== SASL/PLAIN Authentication (port $EXTERNAL_PORT) ===
Admin User:  $ADMIN_USER
Admin Pass:  $ADMIN_PASSWORD
Client User: $CLIENT_USER
Client Pass: $CLIENT_PASSWORD

=== SCRAM-SHA-512 Authentication (port $SECURE_PORT, SSL) ===
Admin User:  scram-$ADMIN_USER
Admin Pass:  $ADMIN_PASSWORD
Client User: scram-$CLIENT_USER
Client Pass: $CLIENT_PASSWORD

SSL Password: $SSL_PASSWORD

=== Connection Examples ===

# Using kcat (kafkacat) - SASL_PLAINTEXT
kcat -b $HOST:$EXTERNAL_PORT -X security.protocol=SASL_PLAINTEXT \\
     -X sasl.mechanism=PLAIN \\
     -X sasl.username=$ADMIN_USER \\
     -X sasl.password=$ADMIN_PASSWORD -L

# Using kafka-console-producer.sh
kafka-console-producer.sh --bootstrap-server $HOST:$EXTERNAL_PORT \\
    --producer-property security.protocol=SASL_PLAINTEXT \\
    --producer-property sasl.mechanism=PLAIN \\
    --producer-property sasl.jaas.config='org.apache.kafka.common.security.plain.PlainLoginModule required username="$ADMIN_USER" password="$ADMIN_PASSWORD";' \\
    --topic test

# Kafka UI: http://localhost:$UI_PORT
EOF
chmod 600 "$SCRIPT_DIR/.kafka-credentials"

# Stop any existing containers
log "Stopping any existing Kafka containers..."
$COMPOSE_CMD -f docker-compose.yml down 2>/dev/null || true
$COMPOSE_CMD -f docker-compose.multi.yml down 2>/dev/null || true
$COMPOSE_CMD -f docker-compose.generated.yml down 2>/dev/null || true

# Generate docker-compose file based on configuration
log "Generating Docker Compose configuration..."

if [[ "$BROKERS" == "1" ]]; then
    # Single broker configuration
    cat > "$SCRIPT_DIR/docker-compose.generated.yml" << 'COMPOSEOF'
version: "3.8"

services:
  broker:
    image: confluentinc/cp-kafka:7.6.1
    container_name: kraft-broker
    hostname: broker
    restart: unless-stopped
    ports:
      - "${EXTERNAL_PORT:-9092}:9092"
      - "${SECURE_PORT:-9094}:9094"
    environment:
      KAFKA_PROCESS_ROLES: broker,controller
      KAFKA_NODE_ID: 1
      KAFKA_LISTENERS: INTERNAL://:9093,EXTERNAL://:9092,SECURE://:9094,CONTROLLER://:9095
      KAFKA_ADVERTISED_LISTENERS: INTERNAL://broker:9093,EXTERNAL://${HOST_IP}:${EXTERNAL_PORT:-9092},SECURE://${HOST_IP}:${SECURE_PORT:-9094}
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: CONTROLLER:PLAINTEXT,INTERNAL:SASL_PLAINTEXT,EXTERNAL:SASL_PLAINTEXT,SECURE:SASL_SSL
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@broker:9095
      KAFKA_INTER_BROKER_LISTENER_NAME: INTERNAL
      CLUSTER_ID: ${CLUSTER_ID}

      KAFKA_AUTO_CREATE_TOPICS_ENABLE: "true"
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
      KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: 1
      KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: 1
      KAFKA_NUM_PARTITIONS: 3
      KAFKA_MIN_INSYNC_REPLICAS: 1

      KAFKA_SASL_ENABLED_MECHANISMS: PLAIN,SCRAM-SHA-512
      KAFKA_SASL_MECHANISM_INTER_BROKER_PROTOCOL: PLAIN
      KAFKA_LISTENER_NAME_INTERNAL_SASL_ENABLED_MECHANISMS: PLAIN
      KAFKA_LISTENER_NAME_INTERNAL_PLAIN_SASL_JAAS_CONFIG: >-
        org.apache.kafka.common.security.plain.PlainLoginModule required
        username="${KAFKA_ADMIN_USER}" password="${KAFKA_ADMIN_PASSWORD}"
        user_${KAFKA_ADMIN_USER}="${KAFKA_ADMIN_PASSWORD}"
        user_${KAFKA_CLIENT_USER}="${KAFKA_CLIENT_PASSWORD}";
      KAFKA_LISTENER_NAME_EXTERNAL_SASL_ENABLED_MECHANISMS: PLAIN
      KAFKA_LISTENER_NAME_EXTERNAL_PLAIN_SASL_JAAS_CONFIG: >-
        org.apache.kafka.common.security.plain.PlainLoginModule required
        username="${KAFKA_ADMIN_USER}" password="${KAFKA_ADMIN_PASSWORD}"
        user_${KAFKA_ADMIN_USER}="${KAFKA_ADMIN_PASSWORD}"
        user_${KAFKA_CLIENT_USER}="${KAFKA_CLIENT_PASSWORD}";
      KAFKA_LISTENER_NAME_SECURE_SASL_ENABLED_MECHANISMS: SCRAM-SHA-512
      KAFKA_LISTENER_NAME_SECURE_SCRAM-SHA-512_SASL_JAAS_CONFIG: >-
        org.apache.kafka.common.security.scram.ScramLoginModule required;
      KAFKA_SSL_KEYSTORE_LOCATION: /etc/kafka/secrets/broker.p12
      KAFKA_SSL_KEYSTORE_PASSWORD: ${SSL_STORE_PASSWORD}
      KAFKA_SSL_KEY_PASSWORD: ${SSL_STORE_PASSWORD}
      KAFKA_SSL_TRUSTSTORE_LOCATION: /etc/kafka/secrets/truststore.p12
      KAFKA_SSL_TRUSTSTORE_PASSWORD: ${SSL_STORE_PASSWORD}
      KAFKA_SSL_KEYSTORE_TYPE: PKCS12
      KAFKA_SSL_TRUSTSTORE_TYPE: PKCS12
      KAFKA_SSL_ENDPOINT_IDENTIFICATION_ALGORITHM: ""
      KAFKA_SUPER_USERS: User:${KAFKA_ADMIN_USER};User:${SCRAM_ADMIN_USER}
    volumes:
      - ./data/kafka:/var/lib/kafka/data
      - ./certs:/etc/kafka/secrets:ro
    healthcheck:
      test: ["CMD-SHELL", "nc -z localhost 9092 || exit 1"]
      interval: 10s
      timeout: 10s
      retries: 5
      start_period: 30s

  user-setup:
    image: confluentinc/cp-kafka:7.6.1
    container_name: kafka-user-setup
    depends_on:
      broker:
        condition: service_started
    environment:
      KAFKA_ADMIN_USER: ${KAFKA_ADMIN_USER}
      KAFKA_ADMIN_PASSWORD: ${KAFKA_ADMIN_PASSWORD}
      SCRAM_CLIENT_USER: ${SCRAM_CLIENT_USER}
      SCRAM_CLIENT_PASSWORD: ${SCRAM_CLIENT_PASSWORD}
      SCRAM_ADMIN_USER: ${SCRAM_ADMIN_USER}
      SCRAM_ADMIN_PASSWORD: ${SCRAM_ADMIN_PASSWORD}
    entrypoint: ["/bin/bash", "/scripts/create_scram_users.sh"]
    volumes:
      - ./scripts:/scripts:ro
COMPOSEOF

else
    # Multi-broker configuration (3 brokers)
    cat > "$SCRIPT_DIR/docker-compose.generated.yml" << 'COMPOSEOF'
version: "3.8"

services:
  broker-1:
    image: confluentinc/cp-kafka:7.6.1
    container_name: kraft-broker-1
    hostname: broker-1
    restart: unless-stopped
    ports:
      - "19092:9092"
      - "19094:9094"
    environment:
      KAFKA_PROCESS_ROLES: broker,controller
      KAFKA_NODE_ID: 1
      KAFKA_LISTENERS: INTERNAL://:9093,EXTERNAL://:9092,SECURE://:9094,CONTROLLER://:9095
      KAFKA_ADVERTISED_LISTENERS: INTERNAL://broker-1:9093,EXTERNAL://${HOST_IP}:19092,SECURE://${HOST_IP}:19094
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: CONTROLLER:PLAINTEXT,INTERNAL:SASL_PLAINTEXT,EXTERNAL:SASL_PLAINTEXT,SECURE:SASL_SSL
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@broker-1:9095,2@broker-2:9095,3@broker-3:9095
      KAFKA_INTER_BROKER_LISTENER_NAME: INTERNAL
      CLUSTER_ID: ${CLUSTER_ID}

      KAFKA_AUTO_CREATE_TOPICS_ENABLE: "true"
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 3
      KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: 3
      KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: 2
      KAFKA_NUM_PARTITIONS: 3
      KAFKA_MIN_INSYNC_REPLICAS: 2

      KAFKA_SASL_ENABLED_MECHANISMS: PLAIN,SCRAM-SHA-512
      KAFKA_SASL_MECHANISM_INTER_BROKER_PROTOCOL: PLAIN
      KAFKA_LISTENER_NAME_INTERNAL_SASL_ENABLED_MECHANISMS: PLAIN
      KAFKA_LISTENER_NAME_INTERNAL_PLAIN_SASL_JAAS_CONFIG: >-
        org.apache.kafka.common.security.plain.PlainLoginModule required
        username="${KAFKA_ADMIN_USER}" password="${KAFKA_ADMIN_PASSWORD}"
        user_${KAFKA_ADMIN_USER}="${KAFKA_ADMIN_PASSWORD}"
        user_${KAFKA_CLIENT_USER}="${KAFKA_CLIENT_PASSWORD}";
      KAFKA_LISTENER_NAME_EXTERNAL_SASL_ENABLED_MECHANISMS: PLAIN
      KAFKA_LISTENER_NAME_EXTERNAL_PLAIN_SASL_JAAS_CONFIG: >-
        org.apache.kafka.common.security.plain.PlainLoginModule required
        username="${KAFKA_ADMIN_USER}" password="${KAFKA_ADMIN_PASSWORD}"
        user_${KAFKA_ADMIN_USER}="${KAFKA_ADMIN_PASSWORD}"
        user_${KAFKA_CLIENT_USER}="${KAFKA_CLIENT_PASSWORD}";
      KAFKA_LISTENER_NAME_SECURE_SASL_ENABLED_MECHANISMS: SCRAM-SHA-512
      KAFKA_LISTENER_NAME_SECURE_SCRAM-SHA-512_SASL_JAAS_CONFIG: >-
        org.apache.kafka.common.security.scram.ScramLoginModule required;
      KAFKA_SSL_KEYSTORE_LOCATION: /etc/kafka/secrets/broker.p12
      KAFKA_SSL_KEYSTORE_PASSWORD: ${SSL_STORE_PASSWORD}
      KAFKA_SSL_KEY_PASSWORD: ${SSL_STORE_PASSWORD}
      KAFKA_SSL_TRUSTSTORE_LOCATION: /etc/kafka/secrets/truststore.p12
      KAFKA_SSL_TRUSTSTORE_PASSWORD: ${SSL_STORE_PASSWORD}
      KAFKA_SSL_KEYSTORE_TYPE: PKCS12
      KAFKA_SSL_TRUSTSTORE_TYPE: PKCS12
      KAFKA_SSL_ENDPOINT_IDENTIFICATION_ALGORITHM: ""
      KAFKA_SUPER_USERS: User:${KAFKA_ADMIN_USER};User:${SCRAM_ADMIN_USER}
    volumes:
      - ./data/broker-1:/var/lib/kafka/data
      - ./certs:/etc/kafka/secrets:ro

  broker-2:
    image: confluentinc/cp-kafka:7.6.1
    container_name: kraft-broker-2
    hostname: broker-2
    restart: unless-stopped
    ports:
      - "29092:9092"
      - "29094:9094"
    environment:
      KAFKA_PROCESS_ROLES: broker,controller
      KAFKA_NODE_ID: 2
      KAFKA_LISTENERS: INTERNAL://:9093,EXTERNAL://:9092,SECURE://:9094,CONTROLLER://:9095
      KAFKA_ADVERTISED_LISTENERS: INTERNAL://broker-2:9093,EXTERNAL://${HOST_IP}:29092,SECURE://${HOST_IP}:29094
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: CONTROLLER:PLAINTEXT,INTERNAL:SASL_PLAINTEXT,EXTERNAL:SASL_PLAINTEXT,SECURE:SASL_SSL
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@broker-1:9095,2@broker-2:9095,3@broker-3:9095
      KAFKA_INTER_BROKER_LISTENER_NAME: INTERNAL
      CLUSTER_ID: ${CLUSTER_ID}

      KAFKA_AUTO_CREATE_TOPICS_ENABLE: "true"
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 3
      KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: 3
      KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: 2
      KAFKA_NUM_PARTITIONS: 3
      KAFKA_MIN_INSYNC_REPLICAS: 2

      KAFKA_SASL_ENABLED_MECHANISMS: PLAIN,SCRAM-SHA-512
      KAFKA_SASL_MECHANISM_INTER_BROKER_PROTOCOL: PLAIN
      KAFKA_LISTENER_NAME_INTERNAL_SASL_ENABLED_MECHANISMS: PLAIN
      KAFKA_LISTENER_NAME_INTERNAL_PLAIN_SASL_JAAS_CONFIG: >-
        org.apache.kafka.common.security.plain.PlainLoginModule required
        username="${KAFKA_ADMIN_USER}" password="${KAFKA_ADMIN_PASSWORD}"
        user_${KAFKA_ADMIN_USER}="${KAFKA_ADMIN_PASSWORD}"
        user_${KAFKA_CLIENT_USER}="${KAFKA_CLIENT_PASSWORD}";
      KAFKA_LISTENER_NAME_EXTERNAL_SASL_ENABLED_MECHANISMS: PLAIN
      KAFKA_LISTENER_NAME_EXTERNAL_PLAIN_SASL_JAAS_CONFIG: >-
        org.apache.kafka.common.security.plain.PlainLoginModule required
        username="${KAFKA_ADMIN_USER}" password="${KAFKA_ADMIN_PASSWORD}"
        user_${KAFKA_ADMIN_USER}="${KAFKA_ADMIN_PASSWORD}"
        user_${KAFKA_CLIENT_USER}="${KAFKA_CLIENT_PASSWORD}";
      KAFKA_LISTENER_NAME_SECURE_SASL_ENABLED_MECHANISMS: SCRAM-SHA-512
      KAFKA_LISTENER_NAME_SECURE_SCRAM-SHA-512_SASL_JAAS_CONFIG: >-
        org.apache.kafka.common.security.scram.ScramLoginModule required;
      KAFKA_SSL_KEYSTORE_LOCATION: /etc/kafka/secrets/broker.p12
      KAFKA_SSL_KEYSTORE_PASSWORD: ${SSL_STORE_PASSWORD}
      KAFKA_SSL_KEY_PASSWORD: ${SSL_STORE_PASSWORD}
      KAFKA_SSL_TRUSTSTORE_LOCATION: /etc/kafka/secrets/truststore.p12
      KAFKA_SSL_TRUSTSTORE_PASSWORD: ${SSL_STORE_PASSWORD}
      KAFKA_SSL_KEYSTORE_TYPE: PKCS12
      KAFKA_SSL_TRUSTSTORE_TYPE: PKCS12
      KAFKA_SSL_ENDPOINT_IDENTIFICATION_ALGORITHM: ""
      KAFKA_SUPER_USERS: User:${KAFKA_ADMIN_USER};User:${SCRAM_ADMIN_USER}
    volumes:
      - ./data/broker-2:/var/lib/kafka/data
      - ./certs:/etc/kafka/secrets:ro

  broker-3:
    image: confluentinc/cp-kafka:7.6.1
    container_name: kraft-broker-3
    hostname: broker-3
    restart: unless-stopped
    ports:
      - "39092:9092"
      - "39094:9094"
    environment:
      KAFKA_PROCESS_ROLES: broker,controller
      KAFKA_NODE_ID: 3
      KAFKA_LISTENERS: INTERNAL://:9093,EXTERNAL://:9092,SECURE://:9094,CONTROLLER://:9095
      KAFKA_ADVERTISED_LISTENERS: INTERNAL://broker-3:9093,EXTERNAL://${HOST_IP}:39092,SECURE://${HOST_IP}:39094
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: CONTROLLER:PLAINTEXT,INTERNAL:SASL_PLAINTEXT,EXTERNAL:SASL_PLAINTEXT,SECURE:SASL_SSL
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@broker-1:9095,2@broker-2:9095,3@broker-3:9095
      KAFKA_INTER_BROKER_LISTENER_NAME: INTERNAL
      CLUSTER_ID: ${CLUSTER_ID}

      KAFKA_AUTO_CREATE_TOPICS_ENABLE: "true"
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 3
      KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: 3
      KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: 2
      KAFKA_NUM_PARTITIONS: 3
      KAFKA_MIN_INSYNC_REPLICAS: 2

      KAFKA_SASL_ENABLED_MECHANISMS: PLAIN,SCRAM-SHA-512
      KAFKA_SASL_MECHANISM_INTER_BROKER_PROTOCOL: PLAIN
      KAFKA_LISTENER_NAME_INTERNAL_SASL_ENABLED_MECHANISMS: PLAIN
      KAFKA_LISTENER_NAME_INTERNAL_PLAIN_SASL_JAAS_CONFIG: >-
        org.apache.kafka.common.security.plain.PlainLoginModule required
        username="${KAFKA_ADMIN_USER}" password="${KAFKA_ADMIN_PASSWORD}"
        user_${KAFKA_ADMIN_USER}="${KAFKA_ADMIN_PASSWORD}"
        user_${KAFKA_CLIENT_USER}="${KAFKA_CLIENT_PASSWORD}";
      KAFKA_LISTENER_NAME_EXTERNAL_SASL_ENABLED_MECHANISMS: PLAIN
      KAFKA_LISTENER_NAME_EXTERNAL_PLAIN_SASL_JAAS_CONFIG: >-
        org.apache.kafka.common.security.plain.PlainLoginModule required
        username="${KAFKA_ADMIN_USER}" password="${KAFKA_ADMIN_PASSWORD}"
        user_${KAFKA_ADMIN_USER}="${KAFKA_ADMIN_PASSWORD}"
        user_${KAFKA_CLIENT_USER}="${KAFKA_CLIENT_PASSWORD}";
      KAFKA_LISTENER_NAME_SECURE_SASL_ENABLED_MECHANISMS: SCRAM-SHA-512
      KAFKA_LISTENER_NAME_SECURE_SCRAM-SHA-512_SASL_JAAS_CONFIG: >-
        org.apache.kafka.common.security.scram.ScramLoginModule required;
      KAFKA_SSL_KEYSTORE_LOCATION: /etc/kafka/secrets/broker.p12
      KAFKA_SSL_KEYSTORE_PASSWORD: ${SSL_STORE_PASSWORD}
      KAFKA_SSL_KEY_PASSWORD: ${SSL_STORE_PASSWORD}
      KAFKA_SSL_TRUSTSTORE_LOCATION: /etc/kafka/secrets/truststore.p12
      KAFKA_SSL_TRUSTSTORE_PASSWORD: ${SSL_STORE_PASSWORD}
      KAFKA_SSL_KEYSTORE_TYPE: PKCS12
      KAFKA_SSL_TRUSTSTORE_TYPE: PKCS12
      KAFKA_SSL_ENDPOINT_IDENTIFICATION_ALGORITHM: ""
      KAFKA_SUPER_USERS: User:${KAFKA_ADMIN_USER};User:${SCRAM_ADMIN_USER}
    volumes:
      - ./data/broker-3:/var/lib/kafka/data
      - ./certs:/etc/kafka/secrets:ro

  user-setup:
    image: confluentinc/cp-kafka:7.6.1
    container_name: kafka-user-setup
    depends_on:
      broker-1:
        condition: service_started
    environment:
      KAFKA_ADMIN_USER: ${KAFKA_ADMIN_USER}
      KAFKA_ADMIN_PASSWORD: ${KAFKA_ADMIN_PASSWORD}
      SCRAM_CLIENT_USER: ${SCRAM_CLIENT_USER}
      SCRAM_CLIENT_PASSWORD: ${SCRAM_CLIENT_PASSWORD}
      SCRAM_ADMIN_USER: ${SCRAM_ADMIN_USER}
      SCRAM_ADMIN_PASSWORD: ${SCRAM_ADMIN_PASSWORD}
      BOOTSTRAP_SERVER: broker-1:9093
    entrypoint: ["/bin/bash", "/scripts/create_scram_users.sh"]
    volumes:
      - ./scripts:/scripts:ro
COMPOSEOF
fi

# Add UI service if enabled
if [[ "$UI" == "true" ]]; then
    if [[ "$BROKERS" == "1" ]]; then
        cat >> "$SCRIPT_DIR/docker-compose.generated.yml" << 'UIEOF'

  kafka-ui:
    image: provectuslabs/kafka-ui:v0.7.2
    container_name: kafka-ui
    restart: unless-stopped
    ports:
      - "${UI_PORT:-8080}:8080"
    environment:
      KAFKA_CLUSTERS_0_NAME: kraft
      KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS: broker:9093
      KAFKA_CLUSTERS_0_PROPERTIES_SECURITY_PROTOCOL: SASL_PLAINTEXT
      KAFKA_CLUSTERS_0_PROPERTIES_SASL_MECHANISM: PLAIN
      KAFKA_CLUSTERS_0_PROPERTIES_SASL_JAAS_CONFIG: org.apache.kafka.common.security.plain.PlainLoginModule required username="${KAFKA_ADMIN_USER}" password="${KAFKA_ADMIN_PASSWORD}";
    depends_on:
      broker:
        condition: service_started
UIEOF
    else
        cat >> "$SCRIPT_DIR/docker-compose.generated.yml" << 'UIEOF'

  kafka-ui:
    image: provectuslabs/kafka-ui:v0.7.2
    container_name: kafka-ui
    restart: unless-stopped
    ports:
      - "${UI_PORT:-8080}:8080"
    environment:
      KAFKA_CLUSTERS_0_NAME: kraft-cluster
      KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS: broker-1:9093,broker-2:9093,broker-3:9093
      KAFKA_CLUSTERS_0_PROPERTIES_SECURITY_PROTOCOL: SASL_PLAINTEXT
      KAFKA_CLUSTERS_0_PROPERTIES_SASL_MECHANISM: PLAIN
      KAFKA_CLUSTERS_0_PROPERTIES_SASL_JAAS_CONFIG: org.apache.kafka.common.security.plain.PlainLoginModule required username="${KAFKA_ADMIN_USER}" password="${KAFKA_ADMIN_PASSWORD}";
    depends_on:
      broker-1:
        condition: service_started
      broker-2:
        condition: service_started
      broker-3:
        condition: service_started
UIEOF
    fi
fi

success "Docker Compose configuration generated"

# Create data directories with container-friendly permissions
prepare_data_dirs

# Start the cluster
log "Starting Kafka cluster..."
if [[ "$DETACH" == "true" ]]; then
    $COMPOSE_CMD -f docker-compose.generated.yml up -d
else
    $COMPOSE_CMD -f docker-compose.generated.yml up
fi

if [[ "$DETACH" == "true" ]]; then
    echo ""
    success "Kafka cluster started successfully!"
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}   Cluster Information${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    if [[ "$BROKERS" == "1" ]]; then
        echo "  Kafka (SASL_PLAINTEXT): $HOST:$EXTERNAL_PORT"
        echo "  Kafka (SASL_SSL):       $HOST:$SECURE_PORT"
    else
        echo "  Kafka (SASL_PLAINTEXT): $HOST:19092, $HOST:29092, $HOST:39092"
        echo "  Kafka (SASL_SSL):       $HOST:19094, $HOST:29094, $HOST:39094"
    fi
    if [[ "$UI" == "true" ]]; then
        echo "  Kafka UI:               http://localhost:$UI_PORT"
    fi
    echo ""
    echo "  Admin User:     $ADMIN_USER"
    echo "  Admin Password: $ADMIN_PASSWORD"
    echo ""
    echo "  Credentials saved to: .kafka-credentials"
    echo ""
    echo -e "${YELLOW}Commands:${NC}"
    echo "  Stop:    ./kafka-stop.sh"
    echo "  Logs:    $COMPOSE_CMD -f docker-compose.generated.yml logs -f"
    echo "  Status:  $COMPOSE_CMD -f docker-compose.generated.yml ps"
    echo "  Test:    ./scripts/test_stack.sh"
    echo ""
fi
