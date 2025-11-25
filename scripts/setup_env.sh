#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${ROOT_DIR}/.setup-config}"
ENV_FILE="${ROOT_DIR}/.env"
CERT_LINK="${ROOT_DIR}/certs"
CERT_HOME_DEFAULT="${ROOT_DIR}/../kafka-kraft-real-certs/certs"
DATA_DIR="${ROOT_DIR}/data-user/kafka"

if [ -f "${CONFIG_FILE}" ]; then
  # shellcheck source=/dev/null
  set -a
  source "${CONFIG_FILE}"
  set +a
fi

prompt_value() {
  local var_name="$1"
  local label="$2"
  local default_value="$3"
  local value
  read -r -p "${label} [${default_value}]: " value
  if [ -z "${value}" ]; then
    value="${default_value}"
  fi
  printf -v "${var_name}" '%s' "${value}"
}

prompt_secret() {
  local var_name="$1"
  local label="$2"
  local default_value="$3"
  local value
  if [ -n "${default_value}" ]; then
    read -r -s -p "${label} [stored]: " value
    echo
  else
    read -r -s -p "${label}: " value
    echo
  fi
  if [ -z "${value}" ]; then
    value="${default_value}"
  fi
  printf -v "${var_name}" '%s' "${value}"
}

detect_host_ip() {
  if [ -n "${HOST_IP:-}" ]; then
    return
  fi
  local cand
  cand=$(hostname -I 2>/dev/null | awk '{for (i=1;i<=NF;i++){if($i!~"^127"){print $i; exit}}}')
  if [ -z "${cand}" ]; then
    cand=$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++){if($i ~ /^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$/){print $i; exit}}}')
  fi
  HOST_IP="${cand:-127.0.0.1}"
}

generate_cluster_id() {
  if [ -n "${CLUSTER_ID:-}" ]; then
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    CLUSTER_ID=$(python3 - <<'PY'
import base64, uuid
u = uuid.uuid4()
raw = u.bytes
encoded = base64.b64encode(raw).decode().rstrip("=")
print(encoded)
PY
)
  fi
  if [ -z "${CLUSTER_ID:-}" ] && command -v uuidgen >/dev/null 2>&1 && command -v xxd >/dev/null 2>&1; then
    CLUSTER_ID=$(uuidgen | tr -d '-' | xxd -r -p | base64 | tr -d '=')
  fi
  CLUSTER_ID="${CLUSTER_ID:-kp7Rzc7oT4GtsqDuqo21Wg}"
}

ensure_data_dir() {
  mkdir -p "${DATA_DIR}"
}

resolve_cert_target() {
  if [ -L "${CERT_LINK}" ] || [ -d "${CERT_LINK}" ]; then
    local resolved
    resolved=$(cd "${CERT_LINK}" 2>/dev/null && pwd || true)
    CERT_TARGET="${resolved:-${CERT_LINK}}"
    return
  fi
  CERT_TARGET="${CERT_HOME_DEFAULT}"
  mkdir -p "${CERT_TARGET}"
  ln -s "${CERT_TARGET}" "${CERT_LINK}"
}

generate_self_signed() {
  if [ "${GENERATE_TLS:-yes}" != "yes" ]; then
    return
  fi
  if [ -z "${SSL_STORE_PASSWORD:-}" ]; then
    echo "SSL_STORE_PASSWORD is empty; skipping TLS generation."
    return
  fi
  if ! command -v openssl >/dev/null 2>&1 || ! command -v keytool >/dev/null 2>&1; then
    echo "openssl and keytool are required to generate TLS materials; skipping."
    return
  fi

  mkdir -p "${CERT_TARGET}"
  local san_conf="${CERT_TARGET}/openssl-san.cnf"
  cat > "${san_conf}" <<EOF
[req]
distinguished_name=req_distinguished_name
req_extensions=v3_req
prompt=no
[req_distinguished_name]
CN=kafka-broker
[v3_req]
keyUsage = keyEncipherment, digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = DNS:${HOSTNAME:-kafka-broker},IP:${HOST_IP}
EOF

  openssl req -x509 -newkey rsa:2048 -days 365 -nodes \
    -subj "/CN=kafka-ca" \
    -keyout "${CERT_TARGET}/ca.key" \
    -out "${CERT_TARGET}/ca.crt"

  openssl req -new -newkey rsa:2048 -nodes \
    -keyout "${CERT_TARGET}/broker.key" \
    -out "${CERT_TARGET}/broker.csr" \
    -config "${san_conf}"

  openssl x509 -req -in "${CERT_TARGET}/broker.csr" \
    -CA "${CERT_TARGET}/ca.crt" -CAkey "${CERT_TARGET}/ca.key" -CAcreateserial \
    -out "${CERT_TARGET}/broker.crt" -days 365 \
    -extensions v3_req -extfile "${san_conf}"

  openssl pkcs12 -export \
    -in "${CERT_TARGET}/broker.crt" -inkey "${CERT_TARGET}/broker.key" -certfile "${CERT_TARGET}/ca.crt" \
    -out "${CERT_TARGET}/broker.p12" -name broker -passout "pass:${SSL_STORE_PASSWORD}"

  keytool -importcert -alias kafka-ca -file "${CERT_TARGET}/ca.crt" \
    -keystore "${CERT_TARGET}/truststore.p12" -storepass "${SSL_STORE_PASSWORD}" -noprompt
}

write_env_file() {
  umask 077
  cat > "${ENV_FILE}" <<EOF
HOST_IP=${HOST_IP}
CLUSTER_ID=${CLUSTER_ID}
KAFKA_ADMIN_USER=${KAFKA_ADMIN_USER}
KAFKA_ADMIN_PASSWORD=${KAFKA_ADMIN_PASSWORD}
KAFKA_CLIENT_USER=${KAFKA_CLIENT_USER}
KAFKA_CLIENT_PASSWORD=${KAFKA_CLIENT_PASSWORD}
SCRAM_ADMIN_USER=${SCRAM_ADMIN_USER}
SCRAM_ADMIN_PASSWORD=${SCRAM_ADMIN_PASSWORD}
SCRAM_CLIENT_USER=${SCRAM_CLIENT_USER}
SCRAM_CLIENT_PASSWORD=${SCRAM_CLIENT_PASSWORD}
SSL_STORE_PASSWORD=${SSL_STORE_PASSWORD}
KAFKA_UI_USERNAME=${KAFKA_UI_USERNAME}
KAFKA_UI_PASSWORD=${KAFKA_UI_PASSWORD}
EOF
}

write_config_file() {
  cat > "${CONFIG_FILE}" <<EOF
HOST_IP=${HOST_IP}
CLUSTER_ID=${CLUSTER_ID}
KAFKA_ADMIN_USER=${KAFKA_ADMIN_USER}
KAFKA_ADMIN_PASSWORD=${KAFKA_ADMIN_PASSWORD}
KAFKA_CLIENT_USER=${KAFKA_CLIENT_USER}
KAFKA_CLIENT_PASSWORD=${KAFKA_CLIENT_PASSWORD}
SCRAM_ADMIN_USER=${SCRAM_ADMIN_USER}
SCRAM_ADMIN_PASSWORD=${SCRAM_ADMIN_PASSWORD}
SCRAM_CLIENT_USER=${SCRAM_CLIENT_USER}
SCRAM_CLIENT_PASSWORD=${SCRAM_CLIENT_PASSWORD}
SSL_STORE_PASSWORD=${SSL_STORE_PASSWORD}
KAFKA_UI_USERNAME=${KAFKA_UI_USERNAME}
KAFKA_UI_PASSWORD=${KAFKA_UI_PASSWORD}
GENERATE_TLS=${GENERATE_TLS}
CERT_TARGET=${CERT_TARGET}
EOF
}

main() {
  detect_host_ip
  generate_cluster_id

  prompt_value HOST_IP "Host/IP clients will reach Kafka on" "${HOST_IP}"
  prompt_value CLUSTER_ID "Cluster ID (base64 UUID, 22 chars)" "${CLUSTER_ID}"
  prompt_value KAFKA_ADMIN_USER "Kafka admin username" "${KAFKA_ADMIN_USER:-admin}"
  prompt_secret KAFKA_ADMIN_PASSWORD "Kafka admin password" "${KAFKA_ADMIN_PASSWORD:-admin-secret}"
  prompt_value KAFKA_CLIENT_USER "Kafka client username (PLAIN)" "${KAFKA_CLIENT_USER:-client}"
  prompt_secret KAFKA_CLIENT_PASSWORD "Kafka client password (PLAIN)" "${KAFKA_CLIENT_PASSWORD:-client-secret}"
  prompt_value SCRAM_ADMIN_USER "SCRAM admin username" "${SCRAM_ADMIN_USER:-scram-admin}"
  prompt_secret SCRAM_ADMIN_PASSWORD "SCRAM admin password" "${SCRAM_ADMIN_PASSWORD:-scram-admin-secret}"
  prompt_value SCRAM_CLIENT_USER "SCRAM client username" "${SCRAM_CLIENT_USER:-scram-client}"
  prompt_secret SCRAM_CLIENT_PASSWORD "SCRAM client password" "${SCRAM_CLIENT_PASSWORD:-scram-client-secret}"
  prompt_secret SSL_STORE_PASSWORD "TLS store password (keystore/truststore)" "${SSL_STORE_PASSWORD:-changeit}"
  prompt_value KAFKA_UI_USERNAME "Kafka UI username (optional auth)" "${KAFKA_UI_USERNAME:-ui-admin}"
  prompt_secret KAFKA_UI_PASSWORD "Kafka UI password (optional auth)" "${KAFKA_UI_PASSWORD:-ui-admin-secret}"

  local tls_default="${GENERATE_TLS:-yes}"
  prompt_value GENERATE_TLS "Generate self-signed TLS materials now? (yes/no)" "${tls_default}"
  if [[ "${GENERATE_TLS,,}" =~ ^y(es)?$ ]]; then
    GENERATE_TLS="yes"
  else
    GENERATE_TLS="no"
  fi

  ensure_data_dir
  resolve_cert_target
  generate_self_signed
  write_env_file
  write_config_file

  cat <<EOF
Setup complete.
- .env written to ${ENV_FILE}
- Cached answers saved to ${CONFIG_FILE} (gitignored)
- Kafka data directory ensured at ${DATA_DIR}
- Certificates in ${CERT_TARGET} (linked from ${CERT_LINK})

Start the stack with:
  docker compose up -d

If TLS was generated here, clients can trust ${CERT_TARGET}/ca.crt or disable hostname verification for self-signed use.
EOF
}

main "$@"
