# Kafka KRaft (no ZooKeeper) with SASL/PLAIN/SCRAM + Kafka UI

Single-broker Apache Kafka in KRaft mode with SASL/PLAIN internally, optional SASL_SSL + SCRAM externally, and Kafka UI. Secrets stay out of git via `.env` (ignored) and a certs symlink that points outside the repo. Data now lives under `./data-user/kafka` (writable by the container user).

## What you need
- Docker + docker compose
- A base64-encoded UUID for `CLUSTER_ID` (22 chars, no padding)
- TLS material (self-signed or real cert) placed outside the repo and symlinked to `certs/`
- Ports available: 9092 (plaintext SASL/PLAIN), 9094/443 (TLS/SCRAM), 8080 (UI)

## Quick start
```bash
git clone https://github.com/sci-ndp/kafka-kraft.git
cd kafka-kraft

# 1) Keep certs out of git: place them outside, then symlink
mkdir -p ../kafka-kraft-real-certs/certs
ln -s ../kafka-kraft-real-certs/certs certs
# copy in your certs: broker.p12, truststore.p12, ca.crt (or see TLS section to generate)

# 2) Prepare data dir (writable by container user 1000)
mkdir -p data-user/kafka

# 3) Create your env (ignored by git) and fill it in
cp .env.example .env
```
Edit `.env`:
- `HOST_IP` = DNS name or IP clients will use
- `SSL_STORE_PASSWORD` = password used to build `broker.p12`/`truststore.p12`
- Set admin/client/SCRAM passwords as you like
- (Optional) `KAFKA_UI_USERNAME` / `KAFKA_UI_PASSWORD` for UI login (see below)

Bring it up:
```bash
docker compose up -d
docker compose ps
```
Kafka UI: http://localhost:8080 (add auth via the optional UI section).  
Secure listener: SASL_SSL + SCRAM on host port 443 (container 9094).  
Plaintext listener: SASL/PLAIN on 9092 (only expose if you mean to).

## Keeping secrets out of git
- `.env` is gitignored; store all passwords there, never in compose files.
- `certs` is a symlink to a directory outside the repo; keep your keys/keystores there.
- Data persists under `./data-user/kafka`; this path is gitignored.
- If you create a `docker-compose.override.yml` with auth or extra tweaks, keep it private (e.g., in `.git/info/exclude`) if it references secret files.

## Kafka endpoints & creds (from `.env`)
- Internal SASL/PLAIN: `SASL_PLAINTEXT://${HOST_IP}:9092`
  - Admin: `${KAFKA_ADMIN_USER}/${KAFKA_ADMIN_PASSWORD}`
  - Client: `${KAFKA_CLIENT_USER}/${KAFKA_CLIENT_PASSWORD}`
- Secure SASL_SSL + SCRAM: `SASL_SSL://${HOST_IP}:9094` (host maps 443→9094)
  - SCRAM users: `${SCRAM_ADMIN_USER}/${SCRAM_ADMIN_PASSWORD}`, `${SCRAM_CLIENT_USER}/${SCRAM_CLIENT_PASSWORD}`
- Re-seed SCRAM users after password changes: `docker compose run --rm user-setup`
- Add another SCRAM user without restart: `./scripts/add_scram_user.sh <user> <pass> [SCRAM-SHA-512]`

## Kafka UI login (optional, keeps creds in `.env`)
Kafka UI ships without auth. To require a username/password:
1) Add to `.env` (already in `.env.example`):
   ```
   KAFKA_UI_USERNAME=ui-admin
   KAFKA_UI_PASSWORD=ui-admin-secret
   ```
2) Create `docker-compose.override.yml` (kept locally) with:
   ```yaml
   services:
     kafka-ui:
       environment:
         KAFKA_UI_AUTH_TYPE: LOGIN_FORM
         KAFKA_UI_AUTH_LOGIN_FORM_USERS_0_USERNAME: ${KAFKA_UI_USERNAME}
         KAFKA_UI_AUTH_LOGIN_FORM_USERS_0_PASSWORD: ${KAFKA_UI_PASSWORD}
         KAFKA_UI_AUTH_LOGIN_FORM_USERS_0_ROLES_0: ADMIN
   ```
3) Restart: `docker compose down && docker compose up -d`

If you prefer proxy-based Basic Auth, front Kafka UI with nginx/caddy and store the htpasswd file outside the repo; point the proxy at `kafka-ui:8080`.

## Remote access (ports, DNS, firewall)
- Set `HOST_IP` to the DNS name/IP clients dial, then recreate the stack.
- Forward 443→443 for the secure listener. Only forward 9092 if you need plaintext. Do not expose 9093 (internal/controller).
- UI on 8080 is optional; protect it (auth or reverse proxy) before exposing.
- Test reachability: `nc -vz <domain> 443` (and 9092 if exposed).

## Sample client configs
- SASL/PLAIN file (`client.properties`):
  ```
  bootstrap.servers=${HOST_IP}:9092
  security.protocol=SASL_PLAINTEXT
  sasl.mechanism=PLAIN
  sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="${KAFKA_CLIENT_USER}" password="${KAFKA_CLIENT_PASSWORD}";
  ```
  Use with CLI: `kafka-topics --bootstrap-server ${HOST_IP}:9092 --command-config client.properties --list`

- SASL_SSL + SCRAM (kcat over 443):
  ```bash
  set -a; source .env; set +a
  printf 'hello\n' | kcat -b "${HOST_IP}:443" \
    -X security.protocol=SASL_SSL \
    -X sasl.mechanisms=SCRAM-SHA-512 \
    -X sasl.username="${SCRAM_CLIENT_USER}" \
    -X sasl.password="${SCRAM_CLIENT_PASSWORD}" \
    -X ssl.ca.location=/etc/ssl/cert.pem \
    -t test_secure -P
  kcat -b "${HOST_IP}:443" \
    -X security.protocol=SASL_SSL \
    -X sasl.mechanisms=SCRAM-SHA-512 \
    -X sasl.username="${SCRAM_CLIENT_USER}" \
    -X sasl.password="${SCRAM_CLIENT_PASSWORD}" \
    -X ssl.ca.location=/etc/ssl/cert.pem \
    -t test_secure -C -o beginning -e -q
  ```
  For self-signed certs, point `ssl.ca.location` to your `certs/ca.crt` and disable hostname verification with `-X ssl.endpoint.identification.algorithm=none` if your SANs don’t match.

## TLS options
- **Self-signed (dev):** Generate outside the repo, symlink into `certs/`, trust `ca.crt` in clients, and set `ssl.endpoint.identification.algorithm=none` if SANs are missing.
- **Regenerate self-signed with your DNS/IP (quick recipe):**
  ```bash
  # prep (outside repo, symlinked to certs/)
  mkdir -p ../kafka-kraft-real-certs/certs
  ln -s ../kafka-kraft-real-certs/certs certs

  # CA
  openssl req -x509 -newkey rsa:2048 -days 365 -nodes \
    -subj "/CN=kafka-ca" \
    -keyout certs/ca.key \
    -out certs/ca.crt

  # SAN config (edit DNS/IP to match your host name)
  cat > certs/openssl-san.cnf <<'EOF'
  [req]
  distinguished_name=req_distinguished_name
  req_extensions=v3_req
  prompt=no
  [req_distinguished_name]
  CN=kafka-broker
  [v3_req]
  keyUsage = keyEncipherment, digitalSignature
  extendedKeyUsage = serverAuth
  subjectAltName = DNS:kafka.example.com,IP:203.0.113.10
  EOF

  # key + csr, then sign
  openssl req -new -newkey rsa:2048 -nodes \
    -keyout certs/broker.key \
    -out certs/broker.csr \
    -config certs/openssl-san.cnf
  openssl x509 -req -in certs/broker.csr \
    -CA certs/ca.crt -CAkey certs/ca.key -CAcreateserial \
    -out certs/broker.crt -days 365 \
    -extensions v3_req -extfile certs/openssl-san.cnf

  # keystore/truststore (uses SSL_STORE_PASSWORD from .env)
  openssl pkcs12 -export \
    -in certs/broker.crt -inkey certs/broker.key -certfile certs/ca.crt \
    -out certs/broker.p12 -name broker -passout pass:${SSL_STORE_PASSWORD}
  keytool -importcert -alias kafka-ca -file certs/ca.crt \
    -keystore certs/truststore.p12 -storepass ${SSL_STORE_PASSWORD} -noprompt
  ```
- **Public cert (e.g., Let’s Encrypt):** Export `broker.p12` and `truststore.p12` from your `fullchain.pem`/`privkey.pem` with the same `SSL_STORE_PASSWORD`; clients can rely on system CAs.
- After changing certs or `SSL_STORE_PASSWORD`, recreate: `docker compose down && docker compose up -d`.

## Secure-only mode (disable plaintext)
- Simplest: do not forward 9092 on your router/firewall; use 443/9094 only.
- Hard disable: remove 9092 mapping and all `EXTERNAL` listener lines from `docker-compose.yml`, then recreate the stack.

## Multi-broker option (3-node KRaft)
- File: `docker-compose.multi.yml`
- External SASL listeners: 19092, 29092, 39092
- Start: `docker compose -f docker-compose.multi.yml up -d`
- Do not run single and multi stacks simultaneously (port and data-dir collisions).

## Smoke test
- `./scripts/test_stack.sh` (auto-detects single vs multi) creates a topic, produces/consumes one message, and cleans up.
- Override topic: `KAFKA_TEST_TOPIC=foo ./scripts/test_stack.sh`
- Use `COMPOSE_CMD="podman compose"` if you run a different compose binary.

## Debugging checklist
- `docker compose ps` and `docker compose logs broker | tail` to confirm the broker is running.
- Advertised listeners: `docker compose exec broker bash -lc 'echo $KAFKA_ADVERTISED_LISTENERS'`.
- TLS sanity: `openssl s_client -connect <domain>:443 -servername <domain>`.
- End-to-end: run the kcat commands above (443 for TLS/SCRAM; 9092 for plaintext only if enabled).

## Notes
- Update `HOST_IP` if your host IP/DNS changes and recreate the stack.
- Data persists under `./data-user/kafka`.
- Images: `confluentinc/cp-kafka:7.6.1` (KRaft) and `provectuslabs/kafka-ui`.
- Keep secrets in `.env` and external cert locations; do not commit them.
