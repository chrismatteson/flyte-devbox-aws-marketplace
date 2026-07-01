#!/bin/bash
set -euo pipefail
source /etc/flyte-devbox/render.env
if [ "$PROD_MODE" != "1" ]; then
  exit 0
fi
# Access-log dir (mounted into the Envoy container). The idle-agent watches this
# log's mtime to treat live console/CLI usage as non-idle.
mkdir -p /var/log/flyte-authproxy
# Confidential client secret (for the Envoy oauth2 browser flow) fetched at
# boot so it is never stored in the template/user-data.
SECRET=$(aws cognito-idp describe-user-pool-client --user-pool-id "$COGNITO_POOL_ID" \
  --client-id "$COGNITO_WEB_CLIENT_ID" --region "$RENDER_REGION" \
  --query "UserPoolClient.ClientSecret" --output text)
# Persistent HMAC for oauth2 cookie signing (survives restarts so sessions persist).
if [ ! -s /etc/flyte-devbox/oauth-hmac ]; then openssl rand -base64 32 | tr -d "\n" > /etc/flyte-devbox/oauth-hmac; fi
HMAC=$(cat /etc/flyte-devbox/oauth-hmac)
# Envoy config template is baked into the AMI at /opt/flyte-devbox/envoy.yaml.tmpl.
cp /opt/flyte-devbox/envoy.yaml.tmpl /etc/flyte-devbox/envoy.yaml
sed -i "s|__ISSUER__|$COGNITO_ISSUER|g; s|__DOMAIN__|$COGNITO_DOMAIN|g; s|__WEB_CLIENT_ID__|$COGNITO_WEB_CLIENT_ID|g; s|__CLIENT_SECRET__|$SECRET|g; s|__HMAC__|$HMAC|g" /etc/flyte-devbox/envoy.yaml
chmod 0600 /etc/flyte-devbox/envoy.yaml
echo "rendered Envoy auth-proxy (oauth2 browser + jwt CLI) config"
