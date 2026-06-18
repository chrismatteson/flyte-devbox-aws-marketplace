# Deploy

## Prerequisites

- An AWS account with admin (or at least CFN-deploy, EC2, S3, ELB, IAM, Lambda, CloudWatch, AWS Backup, SNS) permissions.
- A VPC with at least two subnets in different AZs. The default VPC works fine.
- `aws` CLI configured with credentials.

## Deploy

```bash
aws cloudformation deploy \
  --stack-name flyte-devbox-dev \
  --template-file cloudformation/flyte-devbox.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
      VpcId=vpc-xxxxxxxx \
      SubnetIds=subnet-aaaa,subnet-bbbb \
      AllowedCidr=$(curl -s ifconfig.me)/32 \
      IdleThresholdMinutes=30
```

The template is fully self-contained — the EC2 user-data, the polling agent, and both lambdas are embedded as inline strings. No build step.

First deploy takes 5–10 min:
- ALB / target groups / listener: ~3 min
- EC2 first boot + Docker install + devbox image pull: ~5 min
- AWS Backup vault: instant

## What to expect after deploy

```bash
aws cloudformation describe-stacks --stack-name flyte-devbox-dev \
  --query 'Stacks[0].Outputs' --output table
```

You'll see four outputs:
- `AlbUrl` — open this in a browser. First hit triggers the wake lambda; you'll see "Starting your Flyte devbox…" for ~30 seconds while EC2 boots, then ~3 min while Docker pulls the image, then the Flyte UI.
- `BucketName` — the S3 bucket Flyte uses for object storage (replaces RustFS).
- `InstanceId` — the EC2 instance ID. SSM Session Manager works (`aws ssm start-session --target $InstanceId`).
- `IdleAlarmName` — the CloudWatch alarm that drives auto-stop.

## Sanity checks

After the UI loads:

```bash
# (from your laptop, SSM into the EC2)
aws ssm start-session --target $(aws cloudformation describe-stacks \
  --stack-name flyte-devbox-dev \
  --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' \
  --output text)

# On the EC2 — verify the override config landed
cat /etc/flyte-devbox/config.yaml

# Verify the devbox container is running
sudo docker ps

# Verify the bootstrap ConfigMap got created (this is the override)
sudo /usr/local/bin/kubectl --kubeconfig /var/lib/flyte-devbox-kube/kubeconfig \
  -n flyte get cm flyte-devbox-extra-config -o yaml

# Verify the agent is publishing
sudo journalctl -u flyte-idle-agent -n 20

# Verify the alarm in the AWS console: CloudWatch → Alarms → <stack-name>-flyte-idle
```

## Idle / wake cycle

- **Run a workflow.** Idle metric stays at 0 while it executes.
- **Stop running workflows.** Idle metric ticks up by 1/min.
- **Reach `IdleThresholdMinutes`.** Alarm goes ALARM → SNS → stop lambda → listener flips to wake-tg → EC2 stops.
- **Hit AlbUrl again.** Wake lambda starts EC2 → waking page → ~30s later EC2 boots, devbox is already in its Docker volume (no re-pull), listener flips back to ec2-tg, browser refreshes into the UI.

## Tear down

```bash
aws cloudformation delete-stack --stack-name flyte-devbox-dev
```

Both the **S3 bucket** and the **EBS data volume** are `Retain` / `Snapshot` on delete. To fully clean up:

```bash
# After CFN delete is complete:
aws s3 rb s3://$(aws cloudformation describe-stacks ... BucketName ...) --force
# EBS snapshot from the volume-delete remains in your account; remove manually.
```

## Cost back-of-envelope (us-east-1)

| Component | Idle (EC2 stopped) | Active (EC2 t3.large running) |
|---|---|---|
| ALB | $0.54/day | $0.54/day |
| EC2 t3.large | $0 | $2.00/day |
| EBS gp3 50 GB data | $0.13/day | $0.13/day |
| EBS gp3 30 GB root | $0.08/day | $0.08/day |
| S3 + small data | ~$0/day | ~$0/day |
| CloudWatch metric + alarm | ~$0/day | ~$0/day |
| Lambdas | $0 | ~$0 (rare invocations) |
| **Total** | **~$0.75/day** | **~$2.75/day** |

For an 8-hour workday: ~$1.42/day or ~$43/mo. For a fully idle month: ~$23/mo (almost entirely ALB).
