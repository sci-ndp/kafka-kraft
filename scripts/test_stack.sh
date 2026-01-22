#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source .env if it exists
if [[ -f "$PROJECT_DIR/.env" ]]; then
  set -a
  source "$PROJECT_DIR/.env"
  set +a
fi

COMPOSE_CMD=${COMPOSE_CMD:-"docker compose"}

# Determine which compose file to use
COMPOSE_FILE=""
if [[ -f "$PROJECT_DIR/docker-compose.generated.yml" ]]; then
  COMPOSE_FILE="-f $PROJECT_DIR/docker-compose.generated.yml"
elif [[ -f "$PROJECT_DIR/docker-compose.yml" ]]; then
  COMPOSE_FILE="-f $PROJECT_DIR/docker-compose.yml"
fi

# Detect whether multi-broker stack is running by checking for broker-2 service.
services=$($COMPOSE_CMD $COMPOSE_FILE ps --services 2>/dev/null || true)
if echo "$services" | grep -q "^broker-2$"; then
  MODE="multi"
  BROKER_SERVICE="broker-1"
  BOOTSTRAP="broker-1:9093,broker-2:9093,broker-3:9093"
  REPLICATION_FACTOR=3
else
  MODE="single"
  BROKER_SERVICE="broker"
  BOOTSTRAP="broker:9093"
  REPLICATION_FACTOR=1
fi

ADMIN_USER=${KAFKA_ADMIN_USER:-admin}
ADMIN_PASSWORD=${KAFKA_ADMIN_PASSWORD:-admin-secret}
CLIENT_USER=${KAFKA_CLIENT_USER:-client}
CLIENT_PASSWORD=${KAFKA_CLIENT_PASSWORD:-client-secret}
TOPIC=${KAFKA_TEST_TOPIC:-test-stack}

echo "Detected stack: ${MODE} (service: ${BROKER_SERVICE}, bootstrap: ${BOOTSTRAP})"

# Helper to run a command inside the broker container.
exec_in_broker() {
  ${COMPOSE_CMD} ${COMPOSE_FILE} exec -T "${BROKER_SERVICE}" bash -c "$*"
}

# Build a temp config inside the container (SASL/PLAIN over internal listener).
exec_in_broker "cat > /tmp/client.properties <<'EOF'
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=\"${CLIENT_USER}\" password=\"${CLIENT_PASSWORD}\";
EOF"

exec_in_broker "cat > /tmp/admin.properties <<'EOF'
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=\"${ADMIN_USER}\" password=\"${ADMIN_PASSWORD}\";
EOF"

echo "Creating topic '${TOPIC}'..."
exec_in_broker "kafka-topics --bootstrap-server ${BOOTSTRAP} --command-config /tmp/admin.properties --create --if-not-exists --topic ${TOPIC} --replication-factor ${REPLICATION_FACTOR} --partitions 3"

echo "Producing test message..."
exec_in_broker "printf 'hello-test\n' | kafka-console-producer --bootstrap-server ${BOOTSTRAP} --producer.config /tmp/client.properties --topic ${TOPIC}"

echo "Consuming test message (one record)..."
exec_in_broker "kafka-console-consumer --bootstrap-server ${BOOTSTRAP} --consumer.config /tmp/client.properties --topic ${TOPIC} --from-beginning --max-messages 1"

echo "Deleting topic '${TOPIC}'..."
exec_in_broker "kafka-topics --bootstrap-server ${BOOTSTRAP} --command-config /tmp/admin.properties --delete --topic ${TOPIC}"

echo "Smoke test completed."
