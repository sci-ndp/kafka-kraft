#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <username> <password> [mechanism]" >&2
  echo "Mechanism defaults to SCRAM-SHA-512." >&2
  exit 1
fi

USER_NAME=$1
USER_PASSWORD=$2
MECH=${3:-SCRAM-SHA-512}

COMPOSE_CMD=${COMPOSE_CMD:-"docker compose"}
ADMIN_USER=${KAFKA_ADMIN_USER:?KAFKA_ADMIN_USER required}
ADMIN_PASSWORD=${KAFKA_ADMIN_PASSWORD:?KAFKA_ADMIN_PASSWORD required}

echo "Creating/Updating SCRAM credentials for user '${USER_NAME}' using mechanism ${MECH}..."

$COMPOSE_CMD exec -T broker bash -c "
  set -e
  cat >/tmp/admin.properties <<EOF
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=\"${ADMIN_USER}\" password=\"${ADMIN_PASSWORD}\";
EOF
  kafka-configs --bootstrap-server broker:9093 --command-config /tmp/admin.properties \
    --alter --add-config \"${MECH}=[iterations=4096,password=${USER_PASSWORD}]\" \
    --entity-type users --entity-name ${USER_NAME}
  echo \"User ${USER_NAME} configured with ${MECH}\"
"
