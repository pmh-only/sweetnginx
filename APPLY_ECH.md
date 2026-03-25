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
# ECH: keys loaded
```

One log line appears per nginx worker.

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

Add the following to every `server` block that listens on `443 ssl` or `443 quic`.  The `init_by_lua_block` belongs at the top of the `http` block.

**In `http { ... }`:**

```nginx
init_by_lua_block {
  local function slurp(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local d = f:read("*a"); f:close(); return d
  end
  package.loaded["_cert_pem"] = slurp("/etc/nginx/tls/tls.crt")
  package.loaded["_key_pem"]  = slurp("/etc/nginx/tls/tls.key")
  package.loaded["_ech_pem"]  = slurp("/etc/nginx/ech/server.ech.pem")
}
```

**In each `server { listen 443 ssl; ... }`:**

```nginx
ssl_certificate_by_lua_block {
    local ssl = require "ngx.ssl"
    local ffi = require "ffi"

    if not package.loaded["_ffi_done"] then
        package.loaded["_ffi_done"] = true
        pcall(ffi.cdef, [[
            typedef struct ssl_st            SSL;
            typedef struct ssl_ctx_st        SSL_CTX;
            typedef struct ossl_echstore_st  OSSL_ECHSTORE;
            typedef struct ossl_lib_ctx_st   OSSL_LIB_CTX;
            typedef struct bio_st            BIO;
            OSSL_ECHSTORE *OSSL_ECHSTORE_new(OSSL_LIB_CTX *, const char *);
            void           OSSL_ECHSTORE_free(OSSL_ECHSTORE *);
            BIO           *BIO_new_mem_buf(const void *buf, int len);
            void           BIO_free_all(BIO *);
            int            OSSL_ECHSTORE_read_pem(OSSL_ECHSTORE *, BIO *, int);
            SSL_CTX       *SSL_get_SSL_CTX(const SSL *);
            int            SSL_CTX_set1_echstore(SSL_CTX *, OSSL_ECHSTORE *);
        ]])
    end

    if not package.loaded["_ech_init"] then
        package.loaded["_ech_init"] = true
        local ech_pem = package.loaded["_ech_pem"]
        if ech_pem then
            pcall(function()
                local bio = ffi.C.BIO_new_mem_buf(ech_pem, #ech_pem)
                if bio ~= ffi.null then
                    local es = ffi.C.OSSL_ECHSTORE_new(nil, nil)
                    if es ~= ffi.null then
                        if ffi.C.OSSL_ECHSTORE_read_pem(es, bio, 1) == 1 then
                            package.loaded["_ech_store"] = es
                            ngx.log(ngx.WARN, "ECH: keys loaded")
                        else
                            ffi.C.OSSL_ECHSTORE_free(es)
                        end
                    end
                    ffi.C.BIO_free_all(bio)
                end
            end)
        end
        local cert_pem = package.loaded["_cert_pem"]
        local key_pem  = package.loaded["_key_pem"]
        if cert_pem then package.loaded["_cert_der"] = ssl.cert_pem_to_der(cert_pem) end
        if key_pem  then package.loaded["_key_der"]  = ssl.priv_key_pem_to_der(key_pem) end
    end

    if not package.loaded["_ctx_ech_done"] then
        package.loaded["_ctx_ech_done"] = true
        local es = package.loaded["_ech_store"]
        local ssl_ptr = ssl.get_req_ssl_pointer and ssl.get_req_ssl_pointer()
        if es and ssl_ptr then
            pcall(function()
                local ctx = ffi.C.SSL_get_SSL_CTX(ffi.cast("const struct ssl_st *", ssl_ptr))
                if ctx ~= ffi.null then ffi.C.SSL_CTX_set1_echstore(ctx, es) end
            end)
        end
    end

    local cert_der = package.loaded["_cert_der"]
    local key_der  = package.loaded["_key_der"]
    if not cert_der or not key_der then return ngx.exit(ngx.ERROR) end
    local ok = ssl.clear_certs()
    if not ok then return end
    ssl.set_der_cert(cert_der)
    ssl.set_der_priv_key(key_der)
}
```

Use a distinct `package.loaded` key per server block for the `_ctx_ech_done` guard (e.g. `_ctx_ech_done_quic` for the QUIC block) so each SSL_CTX gets the store set independently.

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
| No `ECH: keys loaded` in logs | Key file missing or unreadable | Check the volume mount and file permissions |
| `ERR_ECH_FALLBACK_CERTIFICATE_INVALID` | ECH store not set on SSL_CTX | Ensure `ssl_certificate_by_lua_block` is present and the key file is mounted |
| Browser shows plaintext SNI | DNS `HTTPS` record missing or not propagated | Verify record with `dig HTTPS example.com` |
| Browser uses HTTP/2 instead of HTTP/3 after ECH enabled | DNS `HTTPS` record missing `alpn="h3 h2"` — browsers use the HTTPS RR exclusively and ignore Alt-Svc | Add `alpn="h3 h2"` to the HTTPS record alongside `ech=` |
| HTTP/3 connections fail after ECH store is set | Unpatched OpenSSL — `ossl_ech_early_decrypt` crashes on QUIC packet format | Ensure the image was built with `patches/openssl-ech-quic-fix.patch` applied |
| `QUIC connection has been shut down` with curl `--ech grease` | curl OSSL-QUIC rejects retry_configs in EncryptedExtensions | Expected curl limitation; real browsers handle this correctly |
