#!/usr/bin/env bash
set -euo pipefail

# ---------- config loader ----------
read_cfg() {
  # usage: read_cfg /path/to/file
  local f="$1"
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"   # ltrim
    line="${line%"${line##*[![:space:]]}"}"   # rtrim
    [ -z "$line" ] && continue
    case "$line" in
      \#*|";"*) continue ;;
    esac
    if [[ "$line" == *"="* ]]; then
      local k="${line%%=*}"
      local v="${line#*=}"
      k="${k%"${k##*[![:space:]]}"}"
      k="${k#"${k%%[![:space:]]*}"}"
      v="${v#"${v%%[![:space:]]*}"}"
      v="${v%"${v##*[![:space:]]}"}"
      # remove optional surrounding quotes
      v="${v%\"}"; v="${v#\"}"
      v="${v%\'}"; v="${v#\'}"
      export "$k=$v"
    fi
  done < "$f"
}

# ---------- resolve BASE_DIR and load config ----------
# BASE_DIR may be passed by caller; if not, try default $HOME/deploy
BASE_DIR="${BASE_DIR:-${HOME:-}/deploy}"
CFG_FILE="$BASE_DIR/shared/.deploy-webhook"

# If BASE_DIR guessed wrong, but config exists in $HOME/deploy, keep it.
# If BASE_DIR empty (HOME missing), try to locate by script path.
if [ -z "${HOME:-}" ]; then
  # script location based fallback
  SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  BASE_DIR="${BASE_DIR:-$SCRIPT_PATH}"
  CFG_FILE="$BASE_DIR/shared/.deploy-webhook"
fi

read_cfg "$CFG_FILE"

# After reading config, BASE_DIR may be overridden there
BASE_DIR="${BASE_DIR:-${HOME:-}/deploy}"
REPO_URL="${REPO_URL:-}"
BRANCH="${BRANCH:-main}"
PUBLIC_LINK="${PUBLIC_LINK:-}"
KEEP_RELEASES="${KEEP_RELEASES:-5}"
WEBHOOK_PATH="${WEBHOOK_PATH:-_deploy/deploy.php}"
WEBHOOK_DIR="${WEBHOOK_DIR:-_deploy}"

REPO_DIR="$BASE_DIR/repo"
RELEASES_DIR="$BASE_DIR/releases"
SHARED_DIR="$BASE_DIR/shared"

LOCK_DIR="$SHARED_DIR/.deploy_lock"
PENDING_FILE="$SHARED_DIR/.deploy_pending"
DEPLOYED_COMMIT_FILE="$SHARED_DIR/DEPLOYED_COMMIT"

mkdir -p "$RELEASES_DIR" "$SHARED_DIR" "$SHARED_DIR/var" "$SHARED_DIR/tools" "$SHARED_DIR/webhook"

# ---------- ensure stable env (php/nohup often lacks HOME/PATH) ----------
export HOME="${HOME:-$(cd "$BASE_DIR/.." && pwd)}"
export PATH="$HOME/bin:$PATH"

export COMPOSER_HOME="${COMPOSER_HOME:-$SHARED_DIR/.composer}"
export COMPOSER_CACHE_DIR="${COMPOSER_CACHE_DIR:-$SHARED_DIR/.composer-cache}"
mkdir -p "$COMPOSER_HOME" "$COMPOSER_CACHE_DIR"

# ---------- lock with pending ----------
if mkdir "$LOCK_DIR" 2>/dev/null; then
  trap 'rmdir "$LOCK_DIR" >/dev/null 2>&1 || true' EXIT
else
  date +%s > "$PENDING_FILE" || true
  echo "Deploy already running. Marked pending and exiting."
  exit 0
fi

# ---------- ensure repo exists ----------
if [ ! -d "$REPO_DIR/.git" ]; then
  if [ -z "$REPO_URL" ]; then
    echo "ERROR: repo not found at $REPO_DIR and REPO_URL is empty in config ($CFG_FILE)" >&2
    exit 1
  fi
  git clone --no-tags --depth 50 --single-branch --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
fi

cd "$REPO_DIR"

# ---------- fetch ONLY branch ----------
git fetch --prune --no-tags origin "$BRANCH"
TARGET_COMMIT="$(git rev-parse --verify "origin/$BRANCH^{commit}")"

# ---------- skip if no changes ----------
CURRENT_COMMIT=""
if [ -f "$DEPLOYED_COMMIT_FILE" ]; then
  CURRENT_COMMIT="$(cat "$DEPLOYED_COMMIT_FILE" 2>/dev/null || true)"
fi

if [ -n "$CURRENT_COMMIT" ] && [ "$CURRENT_COMMIT" = "$TARGET_COMMIT" ]; then
  echo "No changes: already deployed commit $TARGET_COMMIT. Skipping."
  rm -f "$PENDING_FILE" >/dev/null 2>&1 || true
  exit 0
fi

# ---------- create release ----------
RELEASE="$(date +%Y%m%d%H%M%S)"
REL_DIR="$RELEASES_DIR/$RELEASE"
mkdir -p "$REL_DIR"

echo "Deploying ${BRANCH}@${TARGET_COMMIT} -> $REL_DIR"

# export code (no .git)
git archive "$TARGET_COMMIT" | tar -x -C "$REL_DIR"
test -f "$REL_DIR/composer.json"

# ---------- exclusions (rsync-like) ----------
rm -rf "$REL_DIR/.git" "$REL_DIR/.github" 2>/dev/null || true
rm -f  "$REL_DIR/.env" 2>/dev/null || true
# shellcheck disable=SC2115
rm -rf "$REL_DIR/var" "$REL_DIR/node_modules" "$REL_DIR/vendor" "$REL_DIR/tests" 2>/dev/null || true
rm -f  "$REL_DIR/phpunit.xml" "$REL_DIR/phpunit.xml.dist" "$REL_DIR/phpunit.*" 2>/dev/null || true
rm -rf "$REL_DIR/config/packages/test" "$REL_DIR/config/packages/dev" 2>/dev/null || true
rm -f  "$REL_DIR/config/services_test.yaml" 2>/dev/null || true
find "$REL_DIR" -maxdepth 1 -type f \( -name 'docker*' -o -name 'Docker*' \) -print -delete 2>/dev/null || true

# ---------- shared var and env (prepared before switch) ----------
ln -sfn "$SHARED_DIR/var" "$REL_DIR/var"

if [ -f "$SHARED_DIR/.env" ]; then
  ln -sfn "$SHARED_DIR/.env" "$REL_DIR/.env"
  set -a
  # shellcheck disable=SC1090
  . "$SHARED_DIR/.env"
  set +a
fi

# ---------- ensure webhook endpoint exists in release/public ----------
# We keep canonical webhook script in shared/webhook/deploy.php (managed by you).
# Each release gets a symlink at public/<WEBHOOK_PATH>.
REL_PUBLIC_WEBHOOK="$REL_DIR/public/$WEBHOOK_PATH"
REL_PUBLIC_WEBHOOK_DIR="$REL_DIR/public/$WEBHOOK_DIR"
mkdir -p "$(dirname "$REL_PUBLIC_WEBHOOK")"
ln -sfn "$SHARED_DIR/webhook/deploy.php" "$REL_PUBLIC_WEBHOOK"
ln -sfn "$SHARED_DIR/webhook/.htaccess" "$REL_PUBLIC_WEBHOOK_DIR/.htaccess"

cd "$REL_DIR"

# ---------- composer (global or shared fallback) ----------
if command -v composer >/dev/null 2>&1; then
  COMPOSER="composer"
else
  if [ ! -f "$SHARED_DIR/tools/composer.phar" ]; then
    php -r "copy('https://getcomposer.org/composer-stable.phar', '$SHARED_DIR/tools/composer.phar');"
  fi
  COMPOSER="php $SHARED_DIR/tools/composer.phar"
fi

echo "Using composer: $COMPOSER"
$COMPOSER --version || true

$COMPOSER install --no-dev --optimize-autoloader --no-interaction --prefer-dist --no-scripts

# ---------- app tasks ----------
if [ -f "bin/console" ]; then
  php bin/console doctrine:migrations:migrate --no-interaction --env=prod
  php bin/console cache:clear --env=prod
  php bin/console cache:warmup --env=prod
fi

echo "$TARGET_COMMIT" > "$REL_DIR/.DEPLOYED_COMMIT"

# ---------- atomic switch (current) ----------
if [ -d "$BASE_DIR/current" ] && [ ! -L "$BASE_DIR/current" ]; then
  rm -rf "$BASE_DIR/current"
fi
ln -sfn "$REL_DIR" "$BASE_DIR/current"

# Optional: keep DocumentRoot as a symlink in filesystem
if [ -n "$PUBLIC_LINK" ]; then
  rm -rf "$PUBLIC_LINK" 2>/dev/null || true
  ln -s "$BASE_DIR/current/public" "$PUBLIC_LINK"
fi

echo "$TARGET_COMMIT" > "$DEPLOYED_COMMIT_FILE"

# ---------- cleanup old releases ----------
# shellcheck disable=SC2012
ls -1dt "$RELEASES_DIR/"* 2>/dev/null | tail -n +"$((KEEP_RELEASES+1))" | xargs -r rm -rf

echo "OK: release=$RELEASE commit=$TARGET_COMMIT"

# ---------- if pending happened during deploy: run once more ----------
if [ -f "$PENDING_FILE" ]; then
  rm -f "$PENDING_FILE" || true
  echo "Pending deploy detected. Re-running to catch latest ${BRANCH}..."
  exec env BASE_DIR="$BASE_DIR" bash "$BASE_DIR/deploy.sh"
fi
