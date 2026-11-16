# deploy-action

A GitHub Action that deploys an app on your own [CommyPanel](https://github.com/CommyPanel/panel) server. It
installs the [`commy` command](https://github.com/CommyPanel/commy-cli), runs `commy deploy`, waits for the
result and **fails the job if the deployment fails or is rolled back**.

```yaml
name: deploy
on:
  push:
    branches: [main]

permissions:
  contents: read          # the job needs nothing from your repository: CommyPanel fetches the code itself

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production        # optional: a protected environment can require a reviewer first
    steps:
      - name: Deploy
        uses: CommyPanel/deploy-action@<full commit SHA>    # pin a commit, not a branch
        with:
          url: ${{ vars.COMMY_URL }}
          app: shop
          token: ${{ secrets.COMMY_TOKEN }}
```

## Inputs

| Input | Required | What it is |
|---|---|---|
| `url` | yes | The panel address, **https only**, for example `https://panel.example.com`. |
| `app` | yes | The app's short name, as shown in the panel. |
| `token` | yes | An API token, from a repository **secret**. |
| `command` | no | `deploy` (default) or `apply` (make changed variables, volumes and links take effect, no build). |
| `wait` | no | `true` (default): wait and fail the job if it does not go live. `false`: queue it and go on. |
| `timeout` | no | How long to wait, such as `15m` (default) or `900s`. |
| `version` | no | The `commy` version to use. Default: the version this action release was made for (`0.1.0`). |
| `checksum` | no | The SHA-256 of the `commy` binary for the runner, needed only for a version this action does not know. |

**Outputs:** `deployment` (the deployment number) and `status` (`active`, `failed`, `rolled_back`, or `queued`
with `wait: false`).

## The token

Make it under **Settings > API tokens** in the panel, and give it as little as possible:

- **One app** (limit it to the app this job deploys),
- the abilities **`apps:deploy`** and **`apps:read`** (the second only to wait for the result),
- a **short expiry** (30 or 90 days), and rotate it: make a new one, update the secret, revoke the old one.

A leaked token like that can deploy that one app until it expires or you revoke it, and nothing else: it cannot
read logs, change variables, stop apps or see other apps. Anyone who can edit your workflow files can use the
secret, so protect the branch it deploys from, and consider a protected
[environment](https://docs.github.com/actions/deployment/targeting-different-environments) with required
reviewers.

## What the action does and does not do

- **Refuses pull requests.** It stops with an error for `pull_request` and `pull_request_target` runs (and the
  review events): a deployment needs a token, and a pull request is code you have not accepted. Deploy from a
  push to a protected branch, a release or `workflow_dispatch`. Never put the token in a `pull_request_target`
  workflow.
- **Checks what it installs.** `commy` is downloaded from its GitHub release and its SHA-256 is compared with a
  value **kept in this repository** (`checksums/`), not with a file from the release itself, so a changed
  release asset is refused. For a version the action does not know, you must give the checksum yourself.
- **Never splices inputs into a script.** Inputs reach the script as environment variables and are checked
  (an app name, a version, a timeout, an https address) before anything runs.
- **Keeps the token out of the logs**: it is masked, and given to `commy` through the environment only.
- **Switches workflow commands off while `commy` runs.** Text from the panel (an error sentence, a commit
  message) cannot make the log issue commands like `::error::` or `::add-mask::`.
- Runs on **Linux and macOS** runners. It uses no other action and no package manager.

## Without GitHub Actions

Any CI can run the command. For GitLab CI, with `COMMY_URL` and `COMMY_TOKEN` as masked, protected variables:

```yaml
deploy:
  stage: deploy
  image: debian:stable-slim
  rules:
    - if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'
  script:
    - apt-get update -qq && apt-get install -y -qq curl ca-certificates
    - curl -fsSL -o commy https://github.com/CommyPanel/commy-cli/releases/download/v0.1.0/commy_0.1.0_linux_amd64
    - echo "e38d52d21e79e20aab3a6a55e9ee78ba7522db269f96e6c34211a846c961d127  commy" | sha256sum -c -
    - chmod +x commy
    - ./commy deploy shop
```

`commy` exits with `3` when a deployment fails or is rolled back, so the job fails. The checksum is the one for
that exact version and system (see `checksums/` in this repository).

## Development

```bash
bash tests/test.sh              # input checks, checksums, a real download, and the whole flow against a fake panel
SKIP_LIVE=1 bash tests/test.sh  # without the network
```

A new `commy` release is added by putting its `SHA256SUMS` in `checksums/<version>.txt` (taken from the
release) and changing the default `version` in `action.yml`.

Report a security problem privately, as described in [SECURITY.md](SECURITY.md). MIT licensed.
