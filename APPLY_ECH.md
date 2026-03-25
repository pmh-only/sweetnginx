# ECH support in sweetnginx

ECH (Encrypted Client Hello) extensions — both GREASE and real — are silently accepted on all connections (TLS and HTTP/3).  No server-side configuration is needed: without an ECH store, OpenSSL's `tls_parse_ctos_ech` returns early and the connection completes normally using the outer ClientHello.

## Publishing ECHConfigList to DNS (optional)

If you want clients to attempt real ECH, generate a key and publish it:

```sh
# Generate key
mkdir -p /etc/nginx/ech
docker run --rm -v /etc/nginx/ech:/etc/nginx/ech <image> gen-ech-keys <public_name>

# Extract ECHConfigList
docker run --rm -v /etc/nginx/ech:/etc/nginx/ech:ro <image> \
    openssl-ech ech -in /etc/nginx/ech/server.ech.pem -text
```

Add the base64-encoded ECHConfigList to DNS:

```
example.com.  IN  HTTPS  1  .  ech=<base64>
```

Clients will encrypt the real SNI.  The server accepts the connection via the outer ClientHello; ECH is not decrypted (single certificate — no inner-SNI routing needed).

## Key rotation

1. Generate a new key with `gen-ech-keys`.
2. Update the DNS HTTPS record.
3. Reload nginx: `docker exec <container> nginx -s reload`.
4. Remove the old key after the DNS TTL expires.
