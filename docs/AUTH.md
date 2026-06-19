# Auth (Prod mode)

Flyte 2 **OSS has no built-in authentication** on the control plane (UI + gRPC/HTTP
API). So in Prod mode this stack gates access with one or more **static API
tokens**, enforced at the edge — there is no per-user identity or RBAC (that's a
[Union](https://www.union.ai/) feature; this is a single shared-secret gate).

## How it works

```
client ──Authorization: Bearer <token>──►  ALB :443 (HTTPS)
browser ──Authorization: Basic flyte:<token>──►        │
                                                        ▼
                                          on-EC2 Envoy proxy :8080
                                          (Lua checks the token set;
                                           /healthz + /readyz exempt)
                                                        │ ok → h2c
                                                        ▼
                                              devbox (Flyte) :80
```

- **Envoy** (a container on the EC2) sits between the ALB and Flyte and requires a
  valid token on every UI **and** gRPC request. `/healthz` + `/readyz` are exempt
  so the ALB health check passes.
- The **wake Lambda** (Prod auto-stop mode) enforces the same tokens, so only
  authenticated callers can wake (and bill) a stopped box.
- Tokens live in **AWS Secrets Manager**: secret `<stack>-flyte-apikey`, field
  **`apikey`** — a **comma-separated list** of valid tokens. CloudFormation seeds
  one random token on first deploy.

## Client config (CLI)

Flyte 2 OSS can send a static bearer token via the `ExternalCommand` auth type —
it runs a command and sends the output as `Authorization: Bearer <output>`. The
cleanest form reads the token from an env var so it isn't stored in the file:

`~/.flyte/config.yaml`:
```yaml
admin:
  endpoint: dns:///flytedemo.app:443
  authType: ExternalCommand
  command: [sh, -c, "echo $FLYTE_TOKEN"]
task:
  project: flytesnacks
  domain: development
```
Then:
```bash
export FLYTE_TOKEN=<your-token>
flyte run hello.py main
```

> `authType` in the **config file** must be the canonical value `ExternalCommand`
> (the friendly `--auth-type custom` alias is only sanitized for the CLI flag).
>
> Other auth types (`pkce`, `headless`/device-flow, `client-secret`/`app-credential`
> + `FLYTE_API_KEY`) all require a real OAuth2 authorization server / token
> endpoint, which OSS Flyte 2 does not provide — use Union for those.

## Browser (UI) access

Open `https://flytedemo.app/v2`. The browser shows a native auth prompt:
- **Username:** `flyte`
- **Password:** any valid token

## Retrieve the seeded token

```bash
aws secretsmanager get-secret-value \
  --secret-id <stack>-flyte-apikey --region us-east-1 \
  --query SecretString --output text \
| python3 -c 'import sys,json;print(json.load(sys.stdin)["apikey"])'
```
(Also available as the `ApiKeyRetrieveCli` stack output.)

## Add / rotate tokens (in AWS)

Tokens are the comma-separated `apikey` field. To add or rotate:

1. **Edit the secret** — set `apikey` to a comma-separated list, e.g.
   `tok-alice,tok-bob,tok-ci`. Tokens should be URL-safe alphanumerics.
   ```bash
   aws secretsmanager put-secret-value \
     --secret-id <stack>-flyte-apikey --region us-east-1 \
     --secret-string '{"username":"flyte","apikey":"tok-alice,tok-bob,tok-ci"}'
   ```
   (Or edit it in the Secrets Manager console: *Retrieve secret value → Edit*.)

2. **Apply it** — the Envoy proxy re-reads the secret on (re)start:
   ```bash
   aws ssm start-session --target <instance-id>
   sudo systemctl restart flyte-auth-proxy
   ```
   A stop/start (wake) cycle also re-renders it. The **wake Lambda** picks up
   changes automatically (it re-reads the secret on each invoke).

3. **Rotate** by removing the old token from the list and restarting the proxy.
   In-flight clients using the removed token then get `401`.

## Notes

- This is a shared-secret gate, not per-user auth — anyone with a valid token has
  full control-plane access. For SSO / RBAC / per-user API keys, use Union.
- **Wake caveat:** if the box has auto-stopped, the first CLI call may fail with
  `UNAVAILABLE` (the wake Lambda doesn't speak gRPC). Hit `https://flytedemo.app`
  in a browser to wake it, or rerun the CLI after ~90s. Set `AutoStop=No` to avoid.
- Network exposure is also gated by `AllowedCidr` on the ALB security group;
  tighten it to your office/VPN range for defense in depth.
