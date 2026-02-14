# Certs

Private CA and server certificate management for Oatmilk.

## Usage

```sh
./milkman.sh
```

That's it. The interactive guide walks you through everything:

1. **Initialize** the CA (first time setup)
2. **Issue** a new server cert
3. **Renew** a server cert (keep existing key)
4. **Re-issue** a server cert (new key)
5. **Rotate** the CA + all server certs
6. **Verify** a server cert
7. **Nuke** certs and keys
8. **Trust / Untrust** the CA in your system trust store

## Browser Trust

Option 8 adds the CA cert to your OS trust store so browsers trust Oatmilk-signed certs without warnings.

| Platform | What happens |
|---|---|
| macOS | Adds to System Keychain (covers Chrome, Safari, Edge) |
| Debian/Ubuntu | Copies to `/usr/local/share/ca-certificates/` + runs `update-ca-certificates` |
| RHEL/Fedora | Copies to `/etc/pki/ca-trust/source/anchors/` + runs `update-ca-trust` |

Firefox uses its own NSS store — import `oatca/ca.crt` manually via Settings > Privacy & Security > Certificates > View Certificates > Authorities > Import.

## Tests

```sh
bash scripts/test-certs.sh
```

Runs in an isolated temp directory — never touches real certs.
