# Applying ECH to sweetnginx

ECH (Encrypted Client Hello) encrypts the TLS ClientHello so the real SNI is not visible to on-path observers.  The server decrypts the inner ClientHello and confirms ECH to the client.  Inner-SNI routing is not performed — the server serves one certificate unconditionally.

ECH applies to TLS connections only.  The QUIC server block uses a separate SSL_CTX with no ECH store; HTTP/3 clients continue to work normally regardless of whether they send an ECH extension.

## 1. Generate ECH keys

```sh
mkdir -p /etc/nginx/ech
docker run --rm -v /etc/nginx/ech:/etc/nginx/ech <image> gen-ech-keys <public_name>
```

`public_name` is the plaintext outer SNI (e.g. `public.example.com`).
Writes `/etc/nginx/ech/server.ech.pem`.

## 2. Mount the key directory

```sh
docker run -v /etc/nginx/ech:/etc/nginx/ech:ro ... <image>
```

Keys are loaded into the TLS SSL_CTX on the first HTTPS connection per worker.  If the key file is absent, HTTPS works normally without ECH.

## 3. Publish the DNS HTTPS record

```sh
docker run --rm -v /etc/nginx/ech:/etc/nginx/ech:ro <image> \
    openssl-ech ech -in /etc/nginx/ech/server.ech.pem -text
```

Add the base64 ECHConfigList to DNS:

```
example.com.  IN  HTTPS  1  .  ech=<base64>
```

## 4. Verify

```sh
docker logs <container> 2>&1 | grep ECH
# ECH: keys loaded
```

## 5. Key rotation

1. Generate a new key with `gen-ech-keys`.
2. Update the DNS HTTPS record.
3. Reload nginx: `docker exec <container> nginx -s reload`.
4. Remove the old key after the DNS TTL expires.
