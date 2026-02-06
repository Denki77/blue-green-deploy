#!/usr/bin/env bash
set -euo pipefail

# usage:
# ./setup.sh \
#   --base-dir "/home/users/x/user/deploy" \
#   --public-link "/home/users/x/user/public_html/app" \
#   --repo-url "git@github.com:YOU/REPO.git" \
#   --branch "main" \
#   --token "optional-custom-token" \
#   --hidden-url "optional-hidden-url" \
#   --keep 5

BASE_DIR=""
PUBLIC_LINK=""
REPO_URL=""
BRANCH="main"
TOKEN=""
HIDDEN_URL="_deploy"
KEEP_RELEASES="5"

while [ $# -gt 0 ]; do
  case "$1" in
    --base-dir) BASE_DIR="$2"; shift 2;;
    --public-link) PUBLIC_LINK="$2"; shift 2;;
    --repo-url) REPO_URL="$2"; shift 2;;
    --branch) BRANCH="$2"; shift 2;;
    --token) TOKEN="$2"; shift 2;;
    --hidden-url) HIDDEN_URL="$2"; shift 2;;
    --keep) KEEP_RELEASES="$2"; shift 2;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

[ -n "$BASE_DIR" ] || { echo "--base-dir required" >&2; exit 1; }
[ -n "$PUBLIC_LINK" ] || { echo "--public-link required" >&2; exit 1; }
[ -n "$REPO_URL" ] || { echo "--repo-url required" >&2; exit 1; }

# Generate token if not provided
if [ -z "$TOKEN" ]; then
  echo "0) generate DEPLOY_TOKEN"
  if command -v openssl >/dev/null 2>&1; then
    TOKEN="$(openssl rand -hex 32)"   # 64 hex chars
  else
    # fallback: less ideal, but works on minimal systems
    TOKEN="$(date +%s%N | sha256sum | awk '{print $1}')"
  fi
fi

echo "1) create directories"
mkdir -p "$BASE_DIR/shared/webhook" "$BASE_DIR/shared/tools" "$BASE_DIR/shared/var" "$BASE_DIR/releases"

echo "2) install deploy.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "$SCRIPT_DIR/deploy.sh" "$BASE_DIR/deploy.sh"
chmod +x "$BASE_DIR/deploy.sh"

echo "3) install deploy.php"
cp "$SCRIPT_DIR/deploy.php" "$BASE_DIR/shared/webhook/deploy.php"

echo "4) write config"
cat > "$BASE_DIR/shared/.deploy-webhook" <<EOF
DEPLOY_TOKEN=$TOKEN
BASE_DIR=$BASE_DIR
REPO_URL=$REPO_URL
BRANCH=$BRANCH
PUBLIC_LINK=$PUBLIC_LINK
WEBHOOK_PATH=$HIDDEN_URL/deploy.php
KEEP_RELEASES=$KEEP_RELEASES
EOF
chmod 600 "$BASE_DIR/shared/.deploy-webhook"

echo "5) create repo"
if [ ! -d "$BASE_DIR/repo/.git" ]; then
  git clone --no-tags --depth 50 --single-branch --branch "$BRANCH" "$REPO_URL" "$BASE_DIR/repo"
fi

echo "6) Running initial deploy..."
env BASE_DIR="$BASE_DIR" bash "$BASE_DIR/deploy.sh" || true

echo "7) ensure public webhook is a symlink to shared/webhook/deploy.php"
WEBHOOK_PUBLIC_DIR="$BASE_DIR/current/public/$HIDDEN_URL"
WEBHOOK_PUBLIC_PATH="$WEBHOOK_PUBLIC_DIR/deploy.php"
WEBHOOK_SHARED_PATH="$BASE_DIR/shared/webhook/deploy.php"

mkdir -p "$WEBHOOK_PUBLIC_DIR"

if [ -e "$WEBHOOK_PUBLIC_PATH" ] && [ ! -L "$WEBHOOK_PUBLIC_PATH" ]; then
  rm -f "$WEBHOOK_PUBLIC_PATH"
fi

ln -sfn "$WEBHOOK_SHARED_PATH" "$WEBHOOK_PUBLIC_PATH"

echo "8) create DocumentRoot symlink"
rm -rf "$PUBLIC_LINK"
ln -s "$BASE_DIR/current/public" "$PUBLIC_LINK"

echo "Setup done."
echo "Webhook URL should be: https://<your-domain>/$HIDDEN_URL/deploy.php"
echo "X-Deploy-Token in Header: $TOKEN"
