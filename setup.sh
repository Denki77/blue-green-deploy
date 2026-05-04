#!/usr/bin/env bash
set -euo pipefail

write_public_index_wrapper() {
  local public_link="$1"
  local base_dir="$2"

  cat > "$public_link/index.php" <<EOF
<?php

use Symfony\Component\ErrorHandler\Debug;
use Symfony\Component\HttpFoundation\Request;

\$releaseRoot = '$(printf "%s" "$base_dir/current")';

require \$releaseRoot . '/vendor/autoload.php';

if (\$_SERVER['APP_DEBUG'] ?? false) {
    umask(0000);
    Debug::enable();
}

return (require \$releaseRoot . '/config/bootstrap.php')
    ->handle(Request::createFromGlobals())
    ->send();
EOF
}

publish_document_root() {
  local source_dir="$1"
  local public_link="$2"
  local public_name

  public_name="$(basename "$public_link")"

  [ -n "$public_link" ] || return 0
  [ -d "$source_dir" ] || {
    echo "ERROR: source public dir not found: $source_dir" >&2
    exit 1
  }

  if [ "$public_name" != "public_html" ] && { [ -L "$public_link" ] || [ ! -e "$public_link" ]; }; then
    rm -rf "$public_link" 2>/dev/null || true
    ln -s "$source_dir" "$public_link"
    return 0
  fi

  if [ "$public_name" = "public_html" ] && [ ! -d "$public_link" ]; then
    rm -rf "$public_link" 2>/dev/null || true
    mkdir -p "$public_link"
  fi

  if [ -d "$public_link" ]; then
    find "$public_link" -mindepth 1 -maxdepth 1 \
      ! -name '.well-known' \
      ! -name 'cgi-bin' \
      -exec rm -rf {} +

    if [ "$public_name" = "public_html" ]; then
      cp -R "$source_dir"/. "$public_link"/
      write_public_index_wrapper "$public_link" "$BASE_DIR"
    else
      (
        cd "$source_dir"
        find . -mindepth 1 -maxdepth 1 -exec sh -c '
          item="${1#./}"
          ln -sfn "'"$source_dir"'/$item" "'"$public_link"'/$item"
        ' sh {} \;
      )
    fi
    return 0
  fi

  echo "ERROR: PUBLIC_LINK exists and is not a directory or symlink: $public_link" >&2
  exit 1
}

set_default_permissions() {
  local base_dir="$1"

  chmod 755 "$base_dir" "$base_dir/shared" "$base_dir/shared/tools" \
    "$base_dir/shared/webhook" "$base_dir/releases" 2>/dev/null || true
  chmod 775 "$base_dir/shared/var" 2>/dev/null || true

  chmod 700 "$base_dir/deploy.sh" 2>/dev/null || true
  chmod 644 "$base_dir/shared/webhook/deploy.php" "$base_dir/shared/webhook/.htaccess" 2>/dev/null || true
  chmod 600 "$base_dir/shared/.deploy-webhook" 2>/dev/null || true

  if [ -f "$base_dir/shared/.env" ]; then
    chmod 600 "$base_dir/shared/.env" 2>/dev/null || true
  fi

  if [ -f "$base_dir/shared/deploy.log" ]; then
    chmod 640 "$base_dir/shared/deploy.log" 2>/dev/null || true
  fi

  if [ -d "$base_dir/repo" ]; then
    find "$base_dir/repo" -type d -exec chmod 755 {} + 2>/dev/null || true
    find "$base_dir/repo" -type f -exec chmod 644 {} + 2>/dev/null || true
    if [ -d "$base_dir/repo/.git" ]; then
      find "$base_dir/repo/.git" -type d -exec chmod 700 {} + 2>/dev/null || true
      find "$base_dir/repo/.git" -type f -exec chmod 600 {} + 2>/dev/null || true
    fi
  fi

  if [ -d "$base_dir/releases" ]; then
    find "$base_dir/releases" -type d -exec chmod 755 {} + 2>/dev/null || true
    find "$base_dir/releases" -type f -exec chmod 644 {} + 2>/dev/null || true
  fi
}

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
chmod 755 "$BASE_DIR" "$BASE_DIR/shared" "$BASE_DIR/shared/tools" "$BASE_DIR/shared/webhook" "$BASE_DIR/releases"
chmod 775 "$BASE_DIR/shared/var"

echo "2) install deploy.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "$SCRIPT_DIR/deploy.sh" "$BASE_DIR/deploy.sh"
chmod +x "$BASE_DIR/deploy.sh"

echo "3) install deploy.php"
cp "$SCRIPT_DIR/deploy.php" "$BASE_DIR/shared/webhook/deploy.php"
cp "$SCRIPT_DIR/.htaccess" "$BASE_DIR/shared/webhook/.htaccess"

echo "4) write config"
cat > "$BASE_DIR/shared/.deploy-webhook" <<EOF
DEPLOY_TOKEN=$TOKEN
BASE_DIR=$BASE_DIR
REPO_URL=$REPO_URL
BRANCH=$BRANCH
PUBLIC_LINK=$PUBLIC_LINK
WEBHOOK_PATH=$HIDDEN_URL/deploy.php
WEBHOOK_DIR=$HIDDEN_URL
KEEP_RELEASES=$KEEP_RELEASES
EOF
chmod 600 "$BASE_DIR/shared/.deploy-webhook"

HOME_ENV="${HOME:-$(cd "$BASE_DIR/.." && pwd)}/.env"
if [ ! -f "$BASE_DIR/shared/.env" ] && [ -f "$HOME_ENV" ]; then
  echo "4.1) copy existing .env from home directory"
  cp "$HOME_ENV" "$BASE_DIR/shared/.env"
  chmod 600 "$BASE_DIR/shared/.env"
fi

echo "5) create repo"
if [ ! -d "$BASE_DIR/repo/.git" ]; then
  git clone --no-tags --depth 50 --single-branch --branch "$BRANCH" "$REPO_URL" "$BASE_DIR/repo"
fi

set_default_permissions "$BASE_DIR"

echo "6) Running initial deploy..."
env BASE_DIR="$BASE_DIR" bash "$BASE_DIR/deploy.sh" || true

echo "7) ensure public webhook symlinks exist inside current/public"
WEBHOOK_PUBLIC_DIR="$BASE_DIR/current/public/$HIDDEN_URL"
mkdir -p "$WEBHOOK_PUBLIC_DIR"

rm -f "$WEBHOOK_PUBLIC_DIR/deploy.php" 2>/dev/null || true
ln -sfn "$BASE_DIR/shared/webhook/deploy.php" "$WEBHOOK_PUBLIC_DIR/deploy.php"

rm -f "$WEBHOOK_PUBLIC_DIR/.htaccess" 2>/dev/null || true
ln -sfn "$BASE_DIR/shared/webhook/.htaccess" "$WEBHOOK_PUBLIC_DIR/.htaccess"

echo "8) publish DocumentRoot"
publish_document_root "$BASE_DIR/current/public" "$PUBLIC_LINK"

set_default_permissions "$BASE_DIR"

if [ -d "$BASE_DIR/current" ] && [ ! -L "$BASE_DIR/current" ]; then
  chmod 755 "$BASE_DIR/current" 2>/dev/null || true
fi

echo "Setup done."
echo "Webhook URL should be: https://<your-domain>/$HIDDEN_URL/deploy.php"
echo "X-Deploy-Token in Header: $TOKEN"
echo "Add dot env into: $BASE_DIR/shared"
