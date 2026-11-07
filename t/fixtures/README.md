# TLS test fixtures

`cert.crt` and `cert.key` are public test fixtures copied unchanged from
`quiche/examples/` at quiche 0.29.3, commit
`55886df3be579579207104c8e645825b6347a209`.

Source: https://github.com/cloudflare/quiche/tree/0.29.3/quiche/examples

Their license is retained in `COPYING.quiche`. The key is public and only
suitable for the included loopback examples and tests. It is not a deployment
credential. The certificate expires in 2047; test clients disable peer
verification unless a test specifically configures trust.
