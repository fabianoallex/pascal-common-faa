# Test PKI: no security value

**The private keys in this directory are in the repository and public. They protect
nothing. Never use these files outside the test suite, and never reuse the `pipestest`
password.**

A secret scanner will flag this folder. It is right about the fact (a private key in the
repository) and wrong about the risk: this material was generated to be public, so the TLS
tests run on any machine, on both operating systems, without an installed `openssl`.
Generating it in the tests' setup was rejected for that reason: where `openssl` is missing the
TLS tests would vanish, and a suite that stays green while authentication is no longer tested
is worse than a missing test.

Copied from pascal-pipes-faa's `tests/pki` (2026-11-01, `e8c5397`), with two files renamed
into English: `gemea*` → `twin*`, `caixa*` → `cli2*`. The certificates themselves are the same
bytes.

## Files

| Files | Role |
|---|---|
| `ca_cert.pem` / `ca_key.pem` | The test CA, `CN=pipes-faa-test-CA`. A server's `CaFile` for mTLS; a client's `CaFile` to trust the server. |
| `srv_cert.pem` / `srv_key.pem` / `srv.pfx` | Server, `CN=localhost`, SAN `DNS:localhost` and `IP:127.0.0.1`, EKU serverAuth. |
| `cli_cert.pem` / `cli_key.pem` / `cli.pfx` | **Legitimate** client, `CN=pdv-loja-001`, EKU clientAuth, signed by the CA. Must connect. |
| `cli2_cert.pem` / `cli2_key.pem` / `cli2.pfx` | A **second** legitimate client, `CN=caixa-02`, for tests that need two accepted, distinct identities. |
| `rogue_ca_*`, `rogue_cert.pem` / `rogue_key.pem` / `rogue.pfx` | **Intruder**: a well-formed certificate from a CA the server doesn't know (`pipes-faa-rogue-CA`). Must be refused. |
| `twin_ca_*`, `twin_cert.pem` / `twin_key.pem` / `twin.pfx` | Client of a **twin** CA: the same name and serial number as `ca_cert.pem`, another key. Refused only if the root is compared by its bytes, not by issuer + serial. |
| `selfsigned_cert.pem` / `selfsigned_key.pem` / `selfsigned.pfx` | A self-signed client certificate. Must be refused. |

PEM serves OpenSSL (certificate and key apart); PFX serves SChannel (both in one file).
Password of every PFX: `pipestest`.

The intruder, the twin and the self-signed certificate use **the same `CN=pdv-loja-001`** as the
legitimate client, on purpose: if validation ever looked at the name instead of the chain,
their tests would catch it.

Validity: 30 years (until 2056), so the suite doesn't start failing on an arbitrary day.

## Regenerating

```sh
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca_key.pem -out ca_cert.pem \
  -days 10950 -subj "/CN=pipes-faa-test-CA"
# server:   SAN DNS:localhost, IP:127.0.0.1; EKU serverAuth
# clients:  EKU clientAuth, signed by the CA
# intruder: EKU clientAuth, signed by a second CA, the same CN as the client
# PFX:      openssl pkcs12 -export -in X_cert.pem -inkey X_key.pem -out X.pfx -passout pass:pipestest
```

The EKU matters: SChannel's chain check asks for clientAuth on a client certificate and
serverAuth on a server's, so a certificate without it is refused, correctly.
