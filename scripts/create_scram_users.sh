#!/usr/bin/env bash
set -euo pipefail

ADMIN_USER=${KAFKA_ADMIN_USER:-admin}
ADMIN_PASSWORD=${KAFKA_ADMIN_PASSWORD:-admin-secret}
SCRAM_CLIENT_USER=${SCRAM_CLIENT_USER:-scram-client}
SCRAM_CLIENT_PASSWORD=${SCRAM_CLIENT_PASSWORD:-scram-client-secret}
SCRAM_ADMIN_USER=${SCRAM_ADMIN_USER:-scram-admin}
SCRAM_ADMIN_PASSWORD=${SCRAM_ADMIN_PASSWORD:-scram-admin-secret}
BOOTSTRAP=${BOOTSTRAP_SERVER:-${BOOTSTRAP:-broker:9093}}

cat >/tmp/admin.properties <<EOF
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="${ADMIN_USER}" password="${ADMIN_PASSWORD}";
EOF

# Wait for broker to accept SASL_PLAINTEXT connections
for i in $(seq 1 30); do
  if kafka-topics --bootstrap-server "${BOOTSTRAP}" --command-config /tmp/admin.properties --list >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

kafka-configs --bootstrap-server "${BOOTSTRAP}" --command-config /tmp/admin.properties \
  --alter --add-config "SCRAM-SHA-512=[iterations=4096,password=${SCRAM_CLIENT_PASSWORD}]" \
  --entity-type users --entity-name "${SCRAM_CLIENT_USER}"

kafka-configs --bootstrap-server "${BOOTSTRAP}" --command-config /tmp/admin.properties \
  --alter --add-config "SCRAM-SHA-512=[iterations=4096,password=${SCRAM_ADMIN_PASSWORD}]" \
  --entity-type users --entity-name "${SCRAM_ADMIN_USER}"

echo "SCRAM users created (client=${SCRAM_CLIENT_USER}, admin=${SCRAM_ADMIN_USER})"
