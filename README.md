# Blue green deploy

Clone repo and run setup.sh

## Usage

Run setup.sh with parameters

1. `base-dir` - base directory for the project. Example: `/home/users/x/user/deploy`
2. `public-link` - public link - document root. Example: `/home/users/x/user/public_html/app`
3. `branch` - branch to deploy. Example: `main`
4. `repo-url` - repository url. Example: `git@github.com:YOU/REPO.git`
5. `token` - optional custom token for deploy project via webhook. Example: `1234567890`
6. `hidden-url` - optional hidden url for deploy a project via webhook. Example: `https://<your-domain>/hidden-url/deploy.php`. Default: `_deploy`
7. `keep` - optional keep last N releases. Default: `5`

```bash
./setup.sh \
   --base-dir "" \
   --public-link "" \
   --repo-url "" \
   --branch "main" \
   --token "" \
   --hidden-url "" \
   --keep 5
```
