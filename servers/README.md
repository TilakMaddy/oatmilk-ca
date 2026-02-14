Server certificates live here. Each subdirectory is created by `issue-cert.sh` and contains:

- `san_server.cnf` — OpenSSL config (auto-generated)
- `server.key` — private key
- `server.csr` — certificate signing request
- `server.crt` — signed certificate
