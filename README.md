# flyte-devbox-aws-marketplace

A single-EC2 deployment of the [Flyte 2 devbox](https://www.union.ai/docs/v2/union/user-guide/run-modes/running-devbox/) packaged for AWS, with:

- **S3-backed object store** (RustFS replaced via the devbox's `999-extra-config.yaml` override)
- **In-cluster PostgreSQL on a dedicated, snapshotted EBS volume**
- **Auto-stop** of the EC2 when no Flyte executions are running for `IdleThresholdMinutes`
- **Auto-wake** when a user hits the ALB URL (the next request boots the EC2 and serves a "waking" page that auto-refreshes)

## Architecture

```
                          customer browser
                                 |
                          (HTTP, port 80)
                                 |
                                 v
                  +-----------------------------+
                  |  Application Load Balancer  |
                  |   default action: see note  |
                  +-----------------------------+
                       |                    |
              (when EC2 running)   (when EC2 stopped)
                       |                    |
                       v                    v
              +-----------------+   +-----------------+
              |  ec2-tg         |   |  wake-tg        |
              |  (instance:     |   |  (lambda:       |
              |   30080)        |   |   wake handler) |
              +-----------------+   +-----------------+
                       |                    |
                       v                    v
              +-----------------+   StartInstances + 200 HTML
              |  EC2            |   (meta-refresh; once
              |  Ubuntu 24.04   |    healthy, flip listener
              |  Docker         |    back to ec2-tg)
              |  k3s (devbox)   |
              |   :30080 UI/API |
              |                 |
              |  systemd:       |
              |   flyte-devbox  |     +-------------------+
              |   idle-agent ---+---->| CloudWatch metric |
              +-----------------+     | FlyteDevbox/      |
                       |              | IdleMinutes       |
                       v              +-------------------+
              +-----------------+              |
              |  S3 bucket      |              v
              |  (per stack)    |     +-------------------+
              +-----------------+     | Alarm:            |
                                      | IdleMinutes >=    |
              +-----------------+     | threshold         |
              |  EBS volume     |     +-------------------+
              |  /var/lib/      |              |
              |  docker         |              v
              |  (AWS Backup)   |     +-------------------+
              +-----------------+     | Stop lambda:      |
                                      |  flip listener \  |
                                      |  ec2:Stop         |
                                      +-------------------+
```

**Note on listener routing:** the listener's default action forwards to **both** target groups at all times via a weighted forward. The active TG has weight 1, the idle TG has weight 0. The wake and stop lambdas swap the weights via `elbv2:ModifyListener`. Both TGs stay registered in the listener so ALB health checks run continuously on `ec2-tg` — necessary because the wake lambda decides when to flip based on `ec2-tg` health, and ALB only runs health checks on TGs that a listener references.

A second listener rule at priority 1 catches path `=/` and 302-redirects to `/v2`, where the Flyte UI actually lives. Without it, the bare hostname lands on the devbox's `rustfs-s3` traefik ingress and returns `403 application/xml`.

## Layout

```
cloudformation/flyte-devbox.yaml      # the deployable stack (self-contained)
docs/DEPLOY.md                        # deploy walk-through + sanity checks
```

The template embeds the EC2 user-data, the idle-polling agent, and both lambdas inline. There is no separate source tree and no build step: edit the YAML, deploy the YAML.

## Deploy

```bash
aws cloudformation deploy \
  --stack-name flyte-devbox-dev \
  --template-file cloudformation/flyte-devbox.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
      AllowedCidr=YOUR_IP/32 \
      IdleThresholdMinutes=30
```

The template creates its own VPC and two public subnets, so there are no networking parameters to plumb in. Default `VpcCidr` is `10.20.0.0/16`.

> **Do not** pick a `VpcCidr` that overlaps `10.42.0.0/16` (k3s pod CIDR) or `10.43.0.0/16` (k3s service CIDR). If it overlaps, in-cluster DNS lookups inside the devbox get routed to flannel instead of the VPC resolver, and image pulls hang forever.

See `docs/DEPLOY.md` for the post-launch sanity checks.

## What's intentionally _not_ here yet

- Packer-built AMI (v1 uses vanilla Ubuntu 24.04 + user-data; once validated, we lift install steps into a Packer build for the marketplace listing)
- HTTPS via ACM (HTTP-only behind ALB in v1; add a 443 listener + ACM cert as a follow-up)
- Optional external RDS / external S3 bucket parameters (override surface is documented; CFN params can be added in v1.5)
- GPU variant of the devbox image (the `flyte-devbox:gpu-*` image works the same; needs a g4dn/g5 instance type and `nvidia-container-toolkit` in user-data)
