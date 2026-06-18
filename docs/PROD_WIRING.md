# Wiring Prod-mode external backends

When the stack is deployed with `Domain` set (Prod mode), CloudFormation provisions:

- **S3 bucket** — `Outputs.BucketName`
- **RDS Postgres** — `Outputs.ProdDbEndpoint`, password in Secrets Manager (`Outputs.ProdDbSecretArn`)
- **ECR repository** — `Outputs.ProdEcrUri`
- **ALB + ACM cert + Route 53 record + HTTPS** — `Outputs.UiUrlProd`

These resources are **provisioned but not auto-wired into the Flyte devbox chart in v1.** Wiring requires overriding the chart's storage / database / image config and replacing the chart's default in-cluster resources (rustfs, embedded postgres, in-cluster docker registry). The override fights several upstream-chart behaviors (Viper merge semantics, k3s addon reconciler, the SDK's IMDSv1 fallback) and was de-scoped for v1 to keep the deployment story honest.

This document is the recipe for performing the wiring manually until v1.5 automates it.

## What you're trading

| | Default (chart in-cluster) | Wired (external) |
|---|---|---|
| Object storage | rustfs in pod, data on EBS volume | S3 bucket |
| Runs DB | embedded postgres, data on EBS volume | RDS Postgres (single-AZ db.t3.medium) |
| Image registry | in-cluster docker-registry, data on EBS volume | ECR |
| DR story | Snapshot the EBS volume (AWS Backup, already configured) | RDS snapshots + S3 versioning + ECR retention |
| Survives EC2 host failure | Restore EBS volume from snapshot | Yes, everything's external |
| Idle cost | EBS storage only (~$5/mo for 50 GB gp3) | RDS always-on (~$25/mo) + S3 + ECR storage |

## Steps to wire

> Run from SSM Session Manager on the EC2 host (`aws ssm start-session --target $InstanceId`). All steps are inside the devbox container's k3s cluster.

### 1. Edit the per-host override config

```bash
sudo tee /etc/flyte-devbox/config.yaml > /dev/null <<'EOF'
runs:
  storagePrefix: s3://<STACK-BucketName-output>
  database:
    postgres:
      host: <STACK-ProdDbEndpoint-host-portion>
      port: 5432
      dbName: flyte
      user: flyte
      passwordPath: /etc/flyte/secrets/db-password
storage:
  type: stow
  stow:
    kind: s3
    config:
      region: <REGION>
      auth_type: iam
  container: <STACK-BucketName-output>
  signedURL:
    stowConfigOverride:
      endpoint: ""
plugins:
  k8s:
    default-env-vars:
      - AWS_REGION: <REGION>
      - AWS_DEFAULT_REGION: <REGION>
      - _U_EP_OVERRIDE: 'flyte-binary-http.flyte:8090'
      - _U_INSECURE: "true"
      - _U_USE_ACTIONS: "1"
internalApps:
  defaultEnvVars:
    - AWS_REGION: <REGION>
    - AWS_DEFAULT_REGION: <REGION>
    - _U_EP_OVERRIDE: 'flyte-binary-http.flyte:8090'
    - _U_INSECURE: "true"
    - _U_USE_ACTIONS: "1"
EOF
```

### 2. Stage the DB password as a Kubernetes Secret

```bash
PW=$(aws secretsmanager get-secret-value \
       --secret-id <STACK-ProdDbSecretArn-output> \
       --query SecretString --output text \
     | python3 -c 'import sys,json; print(json.load(sys.stdin)["password"])')
docker exec flyte-devbox kubectl -n flyte create secret generic flyte-db-password \
  --from-literal=db-password="$PW" \
  --dry-run=client -o yaml \
| docker exec -i flyte-devbox kubectl apply -f -
```

Then mount it into the flyte-binary pod at `/etc/flyte/secrets/db-password` (kubectl edit deployment, add a `volumeMounts` + `volumes` entry).

### 3. Restart the devbox to pick up the override

```bash
sudo systemctl restart flyte-devbox.service
```

The k3s container restarts; the bootstrap binary rebuilds the manifest with the new config; rustfs and embedded postgres still come up but are unused; flyte-binary reads the override and uses RDS + S3 instead.

### 4. Make IMDSv2 token-fallback explicit (one-time)

Flyte's stow library uses an older AWS SDK that doesn't speak IMDSv2 by default. The template already sets `HttpTokens: optional` to allow v1 fallback, so this should "just work" — but verify by checking that the flyte-binary pod can resolve credentials from IMDS:

```bash
docker exec flyte-devbox kubectl -n flyte logs deploy/flyte-binary \
  | grep -i 'iam\|credentials\|s3'
```

You should see `Found credentials from IAM Role: ...-InstanceRole-...`.

### 5. Verify

```bash
# from your laptop:
flyte run hello.py main
```

Check that the bundle uploaded to your S3 bucket:

```bash
aws s3 ls s3://<STACK-BucketName-output>/uploads/ --recursive
```

## Known sharp edges

- **The k3s addon reconciler watches `/var/lib/rancher/k3s/server/manifests/`.** If you `kubectl edit` the flyte-binary deployment to add the password Secret mount, the reconciler will revert your edit. The robust pattern is to edit the manifest file under that directory directly, so reconcile re-applies your version.

- **Viper merges lists by replace, not item-wise.** Whenever you set `plugins.k8s.default-env-vars` in your override, you must repeat the three Union-internal `_U_*` vars from the chart's `100-inline-config.yaml`, or task pods can't reach the control plane.

- **In-cluster docker-registry is still running** — you can leave it or set its Deployment to 0 replicas. To make Flyte push to ECR instead, set the `flyte-binary.configuration.inline.image.registry` config to `<STACK-ProdEcrUri-output>` and ensure the EC2 instance role can `ecr:GetAuthorizationToken` (the template already grants this in Prod mode).

- **rustfs is still running** too, taking ~50 MB. Same deal — leave it or scale to 0.

## What v1.5 would do

Bake the override + Secret mount + addon-reconciler-safe edits into the user-data so this all happens on first boot. That's a focused project: it depends on the upstream chart's config schema stabilizing and on testing each merge interaction.
