# Applying ECH to sweetnginx

ECH (Encrypted Client Hello) encrypts the TLS ClientHello so the real SNI is not visible to on-path observers.  The server decrypts the inner ClientHello and confirms ECH to the client.  Inner-SNI routing is not performed — the server serves one certificate unconditionally.

ECH applies to both TLS and QUIC (HTTP/3) connections.  Each server block has its own SSL_CTX; both receive the ECH store on the first connection per worker.

---

## 1. Generate ECH keys

Run `gen-ech-keys` inside the container, mounting a host directory to receive the output:

```sh
mkdir -p /etc/nginx/ech
docker run --rm \
  -v /etc/nginx/ech:/etc/nginx/ech \
  <image> gen-ech-keys <public_name>
```

`public_name` is the plaintext outer SNI that clients use when ECH is not yet confirmed (e.g. `public.example.com` or the same hostname as your real domain).

The command writes `/etc/nginx/ech/server.ech.pem` and prints the base64 ECHConfigList to stdout:

```
ECH key written to: /etc/nginx/ech/server.ech.pem

ECHConfigList (for DNS HTTPS RR 'ech=' parameter):
<base64>
```

Keep this base64 string — you will need it for the DNS record in step 3.

---

## 2. Mount the key directory and start the container

Pass the key directory as a read-only volume at `/etc/nginx/ech`:

```sh
docker run -d \
  -p 443:443/tcp \
  -p 443:443/udp \
  -v /etc/nginx/tls:/etc/nginx/tls:ro \
  -v /etc/nginx/ech:/etc/nginx/ech:ro \
  <image>
```

The ECH store is loaded into the TLS and QUIC SSL_CTXs on the first connection handled by each nginx worker.  If the key file is absent the container still starts and HTTPS works normally without ECH.

---

## 3. Publish the DNS HTTPS record

Add a DNS `HTTPS` resource record for your domain containing the ECHConfigList from step 1.  **Always include `alpn="h3 h2"`** — without it browsers will not attempt HTTP/3 even if `Alt-Svc` is present, because a HTTPS RR takes precedence over cached Alt-Svc entries:

```
example.com.  IN  HTTPS  1  .  alpn="h3 h2"  ech=<base64>
```

If you need to re-extract the base64 from an existing key file:

```sh
docker run --rm \
  -v /etc/nginx/ech:/etc/nginx/ech:ro \
  <image> openssl-ech ech -in /etc/nginx/ech/server.ech.pem
```

Or to see full key details:

```sh
docker run --rm \
  -v /etc/nginx/ech:/etc/nginx/ech:ro \
  <image> openssl-ech ech -in /etc/nginx/ech/server.ech.pem -text
```

DNS propagation time depends on your TTL.  Until the record propagates, clients fall back to plaintext SNI.

---

## 4. Verify

**Check that nginx loaded the ECH keys:**

```sh
docker logs <container> 2>&1 | grep ECH
# ECH: keys loaded from "/etc/nginx/ech/server.ech.pem"
```

One log line appears per SSL_CTX (one per server block that inherits the directive).

**Test with curl (requires ECH-capable build):**

```sh
# ECH GREASE — server accepts and responds normally
curl -k --ech grease https://example.com/

# Real ECH — server decrypts inner ClientHello and confirms ECH
curl -k --ech ecl:<base64> https://example.com/
```

**Test in a browser:**

Open `https://example.com/` in Chrome or Firefox.  Navigate to `chrome://net-internals/#dns` or check DevTools → Security tab.  A lock icon with "Encrypted Client Hello" confirms ECH is active.

---

## 5. nginx.conf integration

The TLS (`listen 443 ssl`) and QUIC (`listen 443 quic`) blocks must be **separate server blocks**.  ECH is configured with a single native directive in the `http` block — no Lua required.

**In `http { ... }`:**

```nginx
ssl_ech_key /etc/nginx/ech/server.ech.pem;
```

This directive is processed at configuration time.  It reads the ECH PEM file, builds an `OSSL_ECHSTORE`, and calls `SSL_CTX_set1_echstore` on every SSL_CTX in the virtual host — including both TLS and QUIC server blocks.  If the key file is absent, nginx logs an error and refuses to start; remove the directive if you do not want ECH.

The directive may also be placed at the `server { ... }` level to apply ECH only to specific virtual hosts.


---

## 6. Key rotation

1. Generate a new key:
   ```sh
   docker run --rm -v /etc/nginx/ech:/etc/nginx/ech <image> gen-ech-keys <public_name>
   ```
2. Update the DNS `HTTPS` record with the new base64 ECHConfigList.
3. Wait for the old TTL to expire so all resolvers have the new record.
4. Reload nginx to pick up the new key file:
   ```sh
   docker exec <container> nginx -s reload
   ```

---

## 7. Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| nginx fails to start: `BIO_new_file` or `OSSL_ECHSTORE_read_pem` error | Key file missing or unreadable | Check the volume mount and file permissions |
| `ERR_ECH_FALLBACK_CERTIFICATE_INVALID` | ECH store not set on SSL_CTX | Ensure `ssl_ech_key` directive is present and the key file is mounted |
| Browser shows plaintext SNI | DNS `HTTPS` record missing or not propagated | Verify record with `dig HTTPS example.com` |
| Browser uses HTTP/2 instead of HTTP/3 after ECH enabled | DNS `HTTPS` record missing `alpn="h3 h2"` — browsers use the HTTPS RR exclusively and ignore Alt-Svc | Add `alpn="h3 h2"` to the HTTPS record alongside `ech=` |
| HTTP/3 connections fail after ECH store is set | Unpatched OpenSSL — `ossl_ech_early_decrypt` crashes on QUIC packet format | Ensure the image was built with `patches/openssl-ech-quic-fix.patch` applied |
| `QUIC connection has been shut down` with curl `--ech grease` | curl OSSL-QUIC rejects retry_configs in EncryptedExtensions | Expected curl limitation; real browsers handle this correctly |
