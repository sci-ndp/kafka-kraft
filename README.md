# Kafka KRaft (no ZooKeeper) with SASL/PLAIN

Single-broker Apache Kafka (KRaft mode) with SASL/PLAIN auth, external access bound to your machine IP, auto topic creation enabled, and Kafka UI for visibility.

## Quick start
1) Copy env template: `cp .env.example .env`  
2) Set `HOST_IP` in `.env` to your machine IP (what clients dial).  
3) Optional: adjust users/passwords, `CLUSTER_ID` (22-char base64 UUID), and `SSL_STORE_PASSWORD` if you regenerate certs.  
4) Start single broker: `docker compose up -d`  
5) Kafka UI: http://localhost:8080 (no UI auth; connects over internal SASL_PLAINTEXT).  
6) Secure listener: SASL_SSL + SCRAM on `9094` (443 mapped). Supply certs under `certs/` (symlink), either self-signed or public—see TLS section for commands.

## Step-by-step setup (with commands)
1) Clone and enter:  
   ```bash
   git clone https://github.com/sci-ndp/kafka-kraft.git
   cd kafka-kraft
   ```
2) Place certs where the stack expects them (symlink keeps secrets out of the repo). Example layout one directory above the repo:  
   ```bash
   mkdir -p ../kafka-kraft-real-certs/certs
   # copy or generate your certs into that directory:
   #   broker.p12, broker.key, broker.crt, truststore.p12, ca.crt (or your fullchain/privkey for public certs)
   ln -s ../kafka-kraft-real-certs/certs certs
   ```
   Choose one of:
   - Use an existing self-signed dev bundle you created.
   - Bring a real cert (see “TLS options” below).
   - Regenerate a self-signed bundle with your domain/IP (see “TLS options”).
3) Copy env template:  
   ```bash
   cp .env.example .env
   ```
4) Set `HOST_IP` in `.env` to the public DNS name or IP clients dial (e.g., `kafka.example.com`). Set `SSL_STORE_PASSWORD` to match your keystore/truststore. Adjust user passwords as desired.  
5) If exposing externally, set up router/NAT and firewall: forward TCP 443→443 (secure listener). Only forward 9092 if you intentionally allow plaintext. Do not expose 9093. If you need Kafka UI remotely, forward 8080 (optional, no auth).  
6) Start the stack:  
   ```bash
   docker compose up -d
   ```
7) Verify locally (uses internal listener):  
   ```bash
   HOST_IP=<your-dns-or-ip> ./scripts/test_stack.sh
   ```
8) Verify externally over TLS/SCRAM on 443 with kcat (adjust CA path per your cert choice):  
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
9) To keep plaintext disabled, see “Secure-only mode” below.

## Remote access (ports, DNS, firewall)
- Set `HOST_IP` in `.env` to the DNS name or public IP clients dial (e.g., `kafka.example.com`), then recreate the stack (`docker compose down && docker compose up -d`).
- Router/NAT: forward TCP 443→443 (preferred secure listener, mapped to container 9094). Forward 9092→9092 only if you need plaintext SASL/PLAIN. Kafka UI on 8080 is optional. Do not expose 9093 (internal/controller).
- Allow the same ports on your host firewall. If your router lacks hairpin NAT, internal tests against the public DNS may fail—use the LAN IP or a hosts entry for local checks.
- External reachability sanity: `nc -vz <your-domain> 443` (and 9092 if you expose it).

## Kafka endpoints & creds
- PLAIN (SASL_PLAINTEXT): `SASL_PLAINTEXT://${HOST_IP}:9092`  
  - Admin: `${KAFKA_ADMIN_USER}/${KAFKA_ADMIN_PASSWORD}`  
  - Client: `${KAFKA_CLIENT_USER}/${KAFKA_CLIENT_PASSWORD}`
- Secure (SASL_SSL + SCRAM): `SASL_SSL://${HOST_IP}:9094`  
  - SCRAM users from `.env`: `${SCRAM_ADMIN_USER}/${SCRAM_ADMIN_PASSWORD}`, `${SCRAM_CLIENT_USER}/${SCRAM_CLIENT_PASSWORD}`  
- Auto topic creation is on for easy producer-driven topic creation.
- Re-seed SCRAM users: `docker compose run --rm user-setup` (reads `.env`).
- Add extra SCRAM users live (no restart): `./scripts/add_scram_user.sh <user> <pass> [SCRAM-SHA-512]` (uses admin creds from `.env`).

## Sample client config (for CLI or libraries)
Create `client.properties` (or pass equivalent settings in your client):
```
bootstrap.servers=${HOST_IP}:9092
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="client" password="client-secret";
```
Replace `${HOST_IP}` with the IP you exported above if your tooling does not substitute environment variables in the file.

Example with the Kafka CLI from your host (ensure HOST_IP is exported):
```
kafka-topics --bootstrap-server ${HOST_IP}:9092 --command-config client.properties --list
```

### SASL_SSL + SCRAM example (kcat)
- Self-signed/dev bundle: trust your generated CA (e.g., `certs/ca.crt`) and disable hostname verification: add `-X ssl.ca.location=certs/ca.crt -X ssl.endpoint.identification.algorithm=none`.
- Public cert (e.g., Let’s Encrypt): point to your system trust store (e.g., `/etc/ssl/cert.pem` or `/opt/homebrew/etc/openssl@3/cert.pem`) and keep hostname verification on (omit `ssl.endpoint.identification.algorithm`).
- Produce (adjust CA path based on cert choice):  
  `printf 'hello\n' | kcat -b ${HOST_IP}:9094 -X security.protocol=SASL_SSL -X sasl.mechanisms=SCRAM-SHA-512 -X sasl.username=${SCRAM_CLIENT_USER} -X sasl.password=${SCRAM_CLIENT_PASSWORD} -X ssl.ca.location=/opt/homebrew/etc/openssl@3/cert.pem -t test_secure -P`
- Consume:  
  `kcat -b ${HOST_IP}:9094 -X security.protocol=SASL_SSL -X sasl.mechanisms=SCRAM-SHA-512 -X sasl.username=${SCRAM_CLIENT_USER} -X sasl.password=${SCRAM_CLIENT_PASSWORD} -X ssl.ca.location=/opt/homebrew/etc/openssl@3/cert.pem -t test_secure -C -o beginning -e`
- Prefer 443 for external clients; 9094 is the same listener mapped through the container.

## TLS options: self-signed vs public CA

### Using a self-signed dev bundle
- Place or generate it under `certs/` (symlinked). Clients must trust your `ca.crt` and usually set `ssl.endpoint.identification.algorithm=none` unless you include proper SANs.

### Regenerate self-signed bundle with your DNS/IP
1) Place certs outside the repo and symlink (example):  
   ```bash
   mkdir -p ../kafka-kraft-real-certs/certs
   ln -s ../kafka-kraft-real-certs/certs certs
   ```
2) Pick a password and set `SSL_STORE_PASSWORD` in `.env` (used for keystore/truststore).  
3) Create a CA (replace CN if you like):  
   ```bash
   openssl req -x509 -newkey rsa:2048 -days 365 -nodes \
     -subj "/CN=kafka-ca" \
     -keyout certs/ca.key \
     -out certs/ca.crt
   ```
4) Create a SAN config with your domain/IP:  
   ```bash
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
   ```
   Replace `kafka.example.com` and `203.0.113.10` with your domain/IP.
5) Create key/csr and sign:  
   ```bash
   openssl req -new -newkey rsa:2048 -nodes \
     -keyout certs/broker.key \
     -out certs/broker.csr \
     -config certs/openssl-san.cnf
   openssl x509 -req -in certs/broker.csr \
     -CA certs/ca.crt -CAkey certs/ca.key -CAcreateserial \
     -out certs/broker.crt -days 365 \
     -extensions v3_req -extfile certs/openssl-san.cnf
   ```
6) Build keystore/truststore Kafka expects (uses `SSL_STORE_PASSWORD`):  
   ```bash
   openssl pkcs12 -export \
     -in certs/broker.crt -inkey certs/broker.key -certfile certs/ca.crt \
     -out certs/broker.p12 -name broker -passout pass:${SSL_STORE_PASSWORD}
   keytool -importcert -alias kafka-ca -file certs/ca.crt \
     -keystore certs/truststore.p12 -storepass ${SSL_STORE_PASSWORD} -noprompt
   ```
7) Restart:  
   ```bash
   docker compose down && docker compose up -d
   ```

### Use a real certificate (e.g., Let’s Encrypt)
1) Place certs outside the repo and symlink (if not already):  
   ```bash
   mkdir -p ../kafka-kraft-real-certs/certs
   ln -s ../kafka-kraft-real-certs/certs certs
   ```
2) Obtain `fullchain.pem` and `privkey.pem` (e.g., certbot) and copy them to `certs/live/<your-domain>/`.  
3) Export PKCS#12 and truststore (reuses `SSL_STORE_PASSWORD`):  
   ```bash
   openssl pkcs12 -export \
     -in certs/live/<your-domain>/fullchain.pem \
     -inkey certs/live/<your-domain>/privkey.pem \
     -out certs/broker.p12 -name broker -passout pass:${SSL_STORE_PASSWORD}
   keytool -importcert -alias public-ca \
     -file certs/live/<your-domain>/fullchain.pem \
     -keystore certs/truststore.p12 -storepass ${SSL_STORE_PASSWORD} -noprompt
   ```
4) Set `HOST_IP` to that domain in `.env`, restart the stack, and point clients at your system CA bundle (no need for `ssl.endpoint.identification.algorithm=none`):  
   ```bash
   docker compose down && docker compose up -d
   ```
## Secure-only mode (disable plaintext listener)
- Easiest: do not forward 9092 on your router/firewall. Clients will use 443/9094 (TLS/SCRAM) only.
- Hard disable in the compose file (optional):
  1) In `docker-compose.yml`, remove the `9092:9092` port mapping.  
  2) In `environment`, remove `EXTERNAL://:9092` from `KAFKA_LISTENERS`, remove the `EXTERNAL` entry from `KAFKA_ADVERTISED_LISTENERS`, remove `EXTERNAL` from `KAFKA_LISTENER_SECURITY_PROTOCOL_MAP`, and delete the `KAFKA_LISTENER_NAME_EXTERNAL_*` blocks.  
  3) Recreate: `docker compose down && docker compose up -d`.  
  4) Clients connect via `SASL_SSL://${HOST_IP}:443` (or 9094 if you prefer the raw port).

## Multi-broker option (3-node KRaft)
- Compose file: `docker-compose.multi.yml`
- Ports (external SASL listeners): `19092`, `29092`, `39092`
- Bring it up: `docker compose -f docker-compose.multi.yml up -d`
- Kafka UI (same port 8080): connects internally to the cluster
- For testing the multi stack, use the same compose file in commands, e.g. `COMPOSE_CMD="docker compose -f docker-compose.multi.yml" ./scripts/test_stack.sh`
- Set a stable cluster id if you want to preserve metadata: `export CLUSTER_ID=<base64-uuid>` (defaults to `kp7Rzc7oT4GtsqDuqo21Wg`; must be a base64-encoded UUID, 22 chars, no padding)
- Do not run the single and multi stacks at the same time (port collisions on 8080 and data dirs).

## Tests / smoke check
- After the stack is up, run `./scripts/test_stack.sh` (works for either single or multi; auto-detects).
- The script uses SASL/PLAIN, creates a topic, produces/consumes one message, then deletes the topic.
- Override test topic: `KAFKA_TEST_TOPIC=foo ./scripts/test_stack.sh`
- If using a custom compose command (e.g., podman compose), set `COMPOSE_CMD="podman compose" ./scripts/test_stack.sh`

## Debugging checklist
- `docker compose ps` and `docker compose logs broker | tail` to confirm the broker is up.
- Confirm advertised listeners: `docker compose exec broker bash -lc 'echo $KAFKA_ADVERTISED_LISTENERS'` (should match your domain/IP).
- External reachability: `nc -vz <domain> 443` (and 9092 if exposed).
- TLS sanity: `openssl s_client -connect <domain>:443 -servername <domain>` (should show your cert and an OK verify code).
- End-to-end test: use the kcat commands above (443 for TLS/SCRAM, 9092 for plaintext SASL/PLAIN if enabled).

## Notes
- Update `HOST_IP` if your machine’s IP changes (e.g., wifi switch) and recreate the stack (`docker compose down && docker compose up -d`).
- Data persists under `./data/kafka`.
- Images: `confluentinc/cp-kafka:7.6.1` (Apache Kafka KRaft) and `provectuslabs/kafka-ui` (actively maintained dashboard).
- Default TLS bundle is for dev; regenerate or use a public cert as described above. With a real cert and matching SANs, keep hostname verification on; with self-signed/IP SAN gaps, disable it in clients.
