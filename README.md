# sweetnginx

nginx container image with some sugars for my homelab server

## Components

| Component | Version |
|-----------|---------|
| nginx | 1.29.4 |
| headers-more-nginx-module | v0.38 |
| ModSecurity | v3.0.14 |
| ModSecurity-nginx connector | v1.0.4 |
| OWASP Core Rule Set | v4.24.0 |
| ECH OpenSSL (defo-project) | 3.9.0-ech |

## Nginx modules

### Built-in (static)

| Module | Description |
|--------|-------------|
| `http_ssl_module` | HTTPS support |
| `http_v2_module` | HTTP/2 |
| `http_v3_module` | HTTP/3 / QUIC |
| `http_addition_module` | Append/prepend response bodies |
| `http_auth_request_module` | Subrequest-based authentication |
| `http_dav_module` | WebDAV |
| `http_flv_module` | FLV streaming |
| `http_gunzip_module` | Decompress gzip responses for clients that don't support it |
| `http_gzip_static_module` | Serve pre-compressed `.gz` files |
| `http_mp4_module` | MP4 streaming with seek support |
| `http_random_index_module` | Random directory index |
| `http_realip_module` | Replace client IP from trusted proxy headers |
| `http_secure_link_module` | Token-protected URLs |
| `http_slice_module` | Byte-range cache slicing |
| `http_stub_status_module` | Basic status page |
| `http_sub_module` | Response body substitution |
| `stream` | TCP/UDP proxy |
| `stream_ssl_module` | TLS for stream proxy |
| `stream_ssl_preread_module` | SNI/ALPN inspection without termination |
| `mail` | Mail proxy |
| `mail_ssl_module` | TLS for mail proxy |
| `threads` | Thread pool support |
| `pcre-jit` | JIT-compiled regex |
| `headers-more-nginx-module` | Arbitrary add/set/clear of request and response headers |

### Dynamic

| Module | Description |
|--------|-------------|
| `ngx_http_modsecurity_module` | ModSecurity WAF ← added by this image |
| `ngx_http_brotli_filter_module` | Dynamic Brotli compression ← added by this image |
| `ngx_http_brotli_static_module` | Serve pre-compressed `.br` files ← added by this image |
| `ngx_http_zstd_filter_module` | Dynamic Zstd compression ← added by this image |
| `ngx_http_zstd_static_module` | Serve pre-compressed `.zst` files ← added by this image |

## ECH (Encrypted Client Hello)

ECH encrypts the TLS ClientHello so the SNI (server name) of the real backend is not visible to on-path observers.  Only the outer `public_name` (e.g. a CDN hostname) is transmitted in plaintext.

### Key generation

```sh
docker run --rm -v /etc/nginx/ech:/etc/nginx/ech <image> gen-ech-keys <public_name>
```

This writes `/etc/nginx/ech/server.ech.pem` containing the ECHConfig and private key.

### DNS record

Publish the ECHConfigList as the `ech=` parameter of your DNS HTTPS resource record (type 65):

```
example.com.  HTTPS  1  .  ech=<base64>
```

Get the base64 value from:

```sh
docker run --rm -v /etc/nginx/ech:/etc/nginx/ech <image> \
    openssl-ech ech -in /etc/nginx/ech/server.ech.pem -text
```

### Applying keys

Add `ssl_ech_file` to your HTTPS server block, mount the key directory, and start nginx:

```nginx
server {
    listen 443 ssl;
    ssl_ech_file /etc/nginx/ech/server.ech.pem;
    ...
}
```

```sh
docker run -v /etc/nginx/ech:/etc/nginx/ech:ro ... <image>
# or after rotation:
docker exec <container> /usr/local/openresty/nginx/sbin/nginx -s reload
```

Keys are loaded at startup.  If the key file is absent, HTTPS continues to work normally without ECH.

### Key rotation

Rotate keys periodically (weekly is typical).  Generate a new key, update the DNS record, then reload nginx.  Remove the old key once the DNS TTL has expired.

## Version updates

A GitHub Actions workflow runs every Monday and opens a pull request if any component has a new version available. On merge to `main`, the image is built for `linux/amd64` and `linux/arm64` and pushed to GHCR.
