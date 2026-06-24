# Auth (Prod mode)

Prod mode authenticates with **AWS Cognito** (OAuth2): browser SSO, native CLI
PKCE for humans, and client-credentials (M2M) for CI. No static secrets in client
config.

> Cognito proves *who you are* — there's no per-user RBAC yet, so every
> authenticated principal has full control-plane access (RBAC is a
> [Union](https://www.union.ai/) feature).

## Sign in

**Humans — CLI (PKCE):**
```bash
flyte create config --endpoint dns:///flytedemo.app:443 --auth-type pkce
flyte run --project flytesnacks --domain development hello.py main
```
The first call opens a browser for Cognito login, then caches the token. (Endpoint
is `host:443`, **not** a `/v2` URL; `flyte run` needs `--project`/`--domain`.)

**Browser — UI:** open `https://flytedemo.app/v2` → Cognito login → console.

**CI — M2M (no browser):**
```bash
DOMAIN=https://<stack>-<account>.auth.<region>.amazoncognito.com
TOK=$(curl -s -X POST "$DOMAIN/oauth2/token" \
  -u "$M2M_CLIENT_ID:$M2M_CLIENT_SECRET" \
  -d "grant_type=client_credentials&scope=https://flytedemo.app/access" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
```
Pass it to the CLI via `authType: ExternalCommand`,
`command: [sh, -c, "echo $FLYTE_TOKEN"]`. `CognitoM2MClientId` is a stack output;
the secret is on that Cognito client.

## Manage users & sessions

Create a Cognito user (the pool starts empty):
```bash
aws cognito-idp admin-create-user --user-pool-id <CognitoUserPoolId> \
  --username you@example.com \
  --user-attributes Name=email,Value=you@example.com Name=email_verified,Value=true \
  --temporary-password '<TempPass#1>' --message-action SUPPRESS --region <region>
```
Log out (clear cached tokens — there's no `flyte logout`):
```bash
python -c "from flyte.remote._client.auth._keyring import KeyringStore; \
  KeyringStore.delete('dns:///flytedemo.app:443')"
```

## How it works

ALB :443 → on-EC2 **Envoy** → devbox. Envoy runs two filters: `oauth2` (browser
cookie SSO against Cognito) and `jwt_authn` (validates the Cognito bearer for
CLI/CI). Unauthenticated **API** calls get a `401` instead of a `302` redirect, so
the SDK can log in and retry. An on-box **AuthMetadataService sidecar** serves the
OAuth discovery RPCs that native PKCE needs (the shipped devbox image leaves them
unimplemented).

## Auto-stop & wake

When idle, the box stops and the ALB routes to the **wake Lambda**, which:
- logs **browsers** in via Cognito, then starts the box;
- serves **auth discovery** so the **CLI** can log in while the box is asleep;
- validates the CLI's bearer before starting the box (~2 min boot — re-run once up).

Set `AutoStop=No` for an always-on box (no wake path).

## Known gaps

- `flyte whoami` authenticates but shows `{}` — the OSS devbox doesn't resolve
  identity from the Cognito token (the token itself is valid).
- No per-user RBAC. Network access is also gated by `AllowedCidr` on the ALB
  security group — tighten it to your VPN/office range.

Stack outputs: `CognitoUserPoolId`, `CognitoM2MClientId`, `ClientConfigProd`.
