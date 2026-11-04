# renovate-gcp-runner

A small container image that runs self-hosted [Renovate](https://docs.renovatebot.com/) as its own **GitHub App** on **Google Cloud Run Jobs**, designed to fit inside the Google Cloud free tier.

Published image: [`mystos16/renovate-gcp-runner`](https://hub.docker.com/r/mystos16/renovate-gcp-runner)

## Why this exists

Open-source Renovate only accepts a token (`RENOVATE_TOKEN`). It has no setting for "GitHub App ID plus private key". A GitHub App installation token expires after one hour, so you cannot store a long-lived one in a secret.

This image bridges that gap. On every start it:

1. Reads the GitHub App private key from a mounted file.
2. Signs a short-lived JWT and exchanges it for an installation token through the GitHub API.
3. Starts Renovate with that token.

Result: Renovate acts as `<your-app>[bot]` (not as you), with permissions scoped to the repositories you install the app on, and no personal access token to rotate. The private key lives in Secret Manager, and the image contains no secrets.

The image is the official `renovate/renovate` image (pinned by version and digest) plus two small files, `entrypoint.sh` and `generate-token.js`. It has no extra dependencies.

## How it works

```
Cloud Scheduler --(HTTP, OAuth)--> Cloud Run Job --(runs)--> this image
                                        |
                  Secret Manager --(mounted as /secrets/app-key.pem)
                                        |
                       entrypoint.sh -> generate-token.js -> GitHub API
                                        |
                                    renovate  -->  pull requests
```

## Configuration

All configuration is through environment variables on the Cloud Run Job.

| Variable | Required | Description |
|---|---|---|
| `APP_ID` | yes | GitHub App ID |
| `INSTALLATION_ID` | yes | Installation ID (the number in `github.com/settings/installations/<id>`) |
| `APP_KEY_PATH` | no | Path to the private key PEM. Default `/secrets/app-key.pem` |
| `GITHUB_API_URL` | no | API base URL, for GitHub Enterprise Server. Default `https://api.github.com` |
| `RENOVATE_TOKEN` | no | If already set, token generation is skipped (useful for testing with a PAT) |
| `RENOVATE_PLATFORM` | yes | `github` |
| `RENOVATE_REPOSITORIES` | one of | Comma-separated `owner/repo` list |
| `RENOVATE_AUTODISCOVER` | one of | `true` to process every repo the app is installed on |
| `RENOVATE_GIT_AUTHOR` | recommended | `Name <BOT_ID+app-slug[bot]@users.noreply.github.com>` so commits are attributed to the bot |

Any other [`RENOVATE_*` self-hosted option](https://docs.renovatebot.com/self-hosted-configuration/) works too. Renovate reads each repository's own `renovate.json` for per-repo behaviour.

Arguments passed to the container are forwarded to `renovate`.

## Setup

Follow the steps in order. Each step builds on the previous one. Everything can be done in the web consoles, no command line needed (except optional local testing).

**Prerequisites**

- A Google Cloud project with billing enabled (required even for free-tier use). Select it in the console's project picker before you start.
- A GitHub account that owns the repositories you want Renovate to manage.
- A Docker Hub account (only if you build your own image, see step 1).
- Pick one region for everything, for example `europe-west4`, `us-central1`, `us-east1` or `us-west1`. These are Cloud Run Tier 1 regions (check the Cloud Run pricing page for the current list).

### 1. Get the container image

Choose one:

**A. Build and publish your own (recommended, you control what runs)**

1. Fork or copy this repository to your own GitHub account.
2. No code changes are needed. The workflow publishes to `<your Docker Hub username>/renovate-gcp-runner`, taking the username from the `DOCKERHUB_USERNAME` variable you set below.
3. On Docker Hub, create a public repository named `renovate-gcp-runner`.
4. Create a Docker Hub access token: Account settings > Personal access tokens, **Read & Write**, scoped to that one repository. Copy it once.
5. In your GitHub repository go to Settings > Environments > **New environment** named `dockerhub`:
   - Deployment branches and tags: **Selected branches and tags**, add `main` only.
   - Add the environment **secret** `DOCKERHUB_TOKEN` (paste the token) and the environment **variable** `DOCKERHUB_USERNAME` (your Docker Hub username).
   - Optional: add yourself under Required reviewers to approve each publish.
   - Do not create repository-level secrets for Docker Hub. Only this environment holds the token.
6. Push to `main` (or run the workflow manually from the Actions tab). The `build` workflow builds `linux/amd64`, the architecture Cloud Run uses, and pushes it.
7. Open the finished workflow run > **Summary**. Copy the line `docker.io/<user>/renovate-gcp-runner@sha256:...`. This immutable digest reference is what you give Cloud Run in step 5.

Pull requests only validate the build. They never receive secrets and never push.

**B. Use the prebuilt public image**

Use `docker.io/mystos16/renovate-gcp-runner` with a digest from its [Docker Hub tags page](https://hub.docker.com/r/mystos16/renovate-gcp-runner/tags). You trust the publisher's builds, so prefer option A if you can.

### 2. Create the GitHub App

1. GitHub > Settings > Developer settings > **GitHub Apps > New GitHub App**.
2. Name it (must be globally unique), set any homepage URL, and untick **Webhook > Active**.
3. Repository permissions:
   - Contents: Read and write
   - Pull requests: Read and write
   - Issues: Read and write
   - Workflows: Read and write
   - Metadata: Read-only
   - Commit statuses: Read and write (optional)
4. Where can this app be installed: **Only on this account**. Create the app.
5. On the app page, note the **App ID**, then under **Private keys** click **Generate a private key**. A `.pem` file downloads.
6. Left menu **Install App** > your account > **Install** > **Only select repositories** and select the repos Renovate should manage.
7. After installing, the browser URL is `https://github.com/settings/installations/<NUMBER>`. That number is the **Installation ID**. All repos on the account share it.
8. For commit attribution, open `https://api.github.com/users/<app-slug>%5Bbot%5D` in a browser (the slug is the app name in lowercase with dashes) and note the numeric `id`. Your git author becomes `<app-name> <ID>+<app-slug>[bot]@users.noreply.github.com`.

### 3. Store the private key in Secret Manager

1. Console > **APIs & Services > Library** and enable **Secret Manager API**.
2. **Security > Secret Manager > Create secret**.
3. Name `renovate-app-key`. Under **Upload file** choose the downloaded `.pem` (upload, do not paste, so newlines are preserved). Create the secret.
4. Delete the `.pem` from your computer.

### 4. Create the service accounts

1. **IAM & Admin > Service Accounts > Create service account**.
2. Create `renovate-job`, then **Create and continue > Done**.
3. Create `renovate-scheduler` the same way.
4. Let the job read the key: **Secret Manager** > `renovate-app-key` > **Permissions** tab > **Grant access**. Principal `renovate-job@<project>.iam.gserviceaccount.com`, role **Secret Manager Secret Accessor**. Save.

Grant only these resource-scoped roles. Do not give either account project-wide roles. The scheduler account gets its role in step 7, after the job exists.

### 5. Create the Cloud Run Job

1. Enable the **Cloud Run Admin API** (APIs & Services > Library).
2. **Cloud Run > Jobs > Create job**.
3. Container image URL: the `docker.io/<user>/renovate-gcp-runner@sha256:<digest>` reference from step 1.
4. Job name `renovate`, region as chosen in the prerequisites.
5. Number of tasks `1`. Parallelism: **Limit the number of concurrent tasks** = `1`. Renovate handles repositories one after another inside the single task.
6. Expand **Container(s), Volumes, Connections, Security**:
   - **Container** tab: leave **Container command** and **Container arguments** empty. The image already knows what to run.
   - **Settings** tab: CPU `1`, memory `2 GiB`, task timeout `1800` seconds, max retries `0` (a failing run should not loop and use up free-tier seconds).
   - **Variables & Secrets** tab: add the variables below.
   - **Volumes** tab: **Add volume**, type **Secret**, volume name `app-key`, secret `renovate-app-key`, path 1 `app-key.pem` with version `latest`. Then on the **Container** tab, under volume mounts, mount `app-key` at `/secrets`.
   - **Security** tab: service account `renovate-job`.
7. **Create**.

Variables to add (do **not** add `RENOVATE_TOKEN`; the image creates it each run):

| Name | Value |
|---|---|
| `APP_ID` | App ID from step 2 |
| `INSTALLATION_ID` | Installation ID from step 2 |
| `RENOVATE_PLATFORM` | `github` |
| `RENOVATE_REPOSITORIES` | `owner/repo1,owner/repo2` (comma-separated), or use `RENOVATE_AUTODISCOVER` = `true` instead |
| `RENOVATE_GIT_AUTHOR` | `<app-name> <ID>+<app-slug>[bot]@users.noreply.github.com` from step 2 |
| `LOG_LEVEL` | `info` |

### 6. Test run

1. On the job page click **Execute**, then open the execution and its **Logs** tab.
2. On GitHub, each managed repository should now show a **Dependency Dashboard** issue and update pull requests authored by `<app-name>[bot]`.
3. A repository without a `renovate.json` first gets an onboarding pull request. Merge it to activate Renovate there. Each repository's own `renovate.json` controls its behaviour. To share one config, use `"extends": ["github>owner/shared-repo"]` in the others.

If it fails, see [Troubleshooting](#troubleshooting).

### 7. Schedule it

1. Enable the **Cloud Scheduler API**.
2. Let the scheduler start the job: Cloud Run > Jobs > `renovate` > **Permissions** tab (or the info panel) > **Add principal**. Principal `renovate-scheduler@<project>.iam.gserviceaccount.com`, role **Cloud Run Invoker**. Save.
3. **Cloud Scheduler > Create job**. Name `renovate-schedule`, same region as the job.
4. Frequency, for example `0 */8 * * *` (every 8 hours), and your timezone. Continue.
5. Target **HTTP**, method **POST**, URL:
   `https://run.googleapis.com/v2/projects/<PROJECT_ID>/locations/<REGION>/jobs/renovate:run`
6. Auth header **Add OAuth token**, service account `renovate-scheduler`, scope `https://www.googleapis.com/auth/cloud-platform`. Create.
7. On the schedule row use Actions > **Force run**, then check the job's Executions tab.

### 8. Add a budget alert (recommended)

1. **Billing > Budgets & alerts > Create budget**, scoped to your project (all services, credits included).
2. Amount: **Specified amount**, for example `1`.
3. Thresholds: 50% actual, 100% actual, and optionally 100% forecasted. Keep email notifications to billing admins on.

Budgets only alert and do not stop spending, and billing data lags by hours.

## Cost

For a few repositories the job runs a few minutes per execution. At 1 vCPU and 2 GiB, a run every 8 hours stays well inside the Cloud Run free tier (240,000 vCPU-seconds and 450,000 GiB-seconds per month at the time of writing). Cloud Scheduler includes 3 free jobs per billing account, and Secret Manager includes 6 free secret versions. Pricing and free-tier limits change, so confirm on the Google Cloud pricing pages.

## Local testing (optional)

Requires Docker. Use a dry run so nothing is changed on GitHub:

```bash
docker build -t renovate-gcp-runner .
docker run --rm \
  -e APP_ID=123456 -e INSTALLATION_ID=7890123 \
  -e RENOVATE_PLATFORM=github -e RENOVATE_REPOSITORIES=owner/repo \
  -e RENOVATE_DRY_RUN=full -e LOG_LEVEL=debug \
  -v "$PWD/app-key.pem:/secrets/app-key.pem:ro" \
  renovate-gcp-runner
```

On Apple Silicon add `--platform linux/amd64` to both the build and the run. Keep the `.pem` outside the repository directory, or rely on `.gitignore`, which excludes `*.pem`.

## Versioning

Each push to `main` that changes the image publishes it under the workflow run number (`:1`, `:2`, ...) and `:latest`. Pin the Cloud Run Job to the `@sha256:` digest shown in the run summary. A digest is immutable, so even if the Docker Hub account were compromised, the job keeps running the exact image you approved. To roll out a change, push, wait for the workflow, copy the new digest from its summary, then edit the Cloud Run Job (Edit > Container image URL) and save.

### Keeping this repository up to date

The base Renovate image is pinned by version and digest in the `Dockerfile`, and the GitHub Actions are pinned by commit SHA. The included `renovate.json` (preset `config:best-practices`) lets Renovate update both, including the digests, so this repository should be managed by your own Renovate instance, the one this image runs. To enable that:

1. Make sure the GitHub App from step 2 is installed on this repository (Settings > Applications > your app > Configure > add the repository).
2. Add `owner/this-repo` to `RENOVATE_REPOSITORIES` on the Cloud Run Job (or use `RENOVATE_AUTODISCOVER`).
3. Set up the branch protection described below.

Pull requests opened by the app use its installation token, so the `validate` workflow runs on them normally. The workflow has no path filter on pull requests on purpose: a required check that is skipped by a path filter never reports, and would block automerge forever.

What Renovate will propose, on Mondays before 06:00:

- **Base image:** a pull request bumping the `renovate/renovate` tag and digest in the `Dockerfile`.
- **GitHub Actions:** one grouped pull request bumping the pinned action versions and commit SHAs.

Merging a base image or action update to `main` changes the build inputs, so the `build` workflow publishes a new image automatically. Then update the Cloud Run Job to the new digest as described above. The pull request itself runs the validation build first, which catches a broken base image before it is published.

Minor, patch and digest updates are automerged once the required checks pass. Major updates are never automerged and get a `major-update` label for manual review. Automerge uses GitHub's native auto-merge (`platformAutomerge`), which only merges after the required status checks succeed, so set it up first:

1. Settings > General > Pull Requests: tick **Allow auto-merge**.
2. Settings > Branches (or Rules > Rulesets): protect `main` and **require status checks to pass**, selecting the `validate` job of the `build` workflow. Without a required check, GitHub merges immediately without waiting for the build.

Because the Cloud Run Job is pinned to an image digest, an automerged base image update publishes a new image but does not change what runs until you update the job's digest, so you stay in control of what executes with write access to your repositories.

## Secrets handling

Every credential has exactly one home, and none appear in code, the image, logs or the job configuration.

| Secret | Stored in | Used by | Never in |
|---|---|---|---|
| GitHub App private key | Google Secret Manager | Cloud Run Job, via a mounted read-only volume | image, env var, repo, logs |
| GitHub installation token | memory of the running job only (1 hour lifetime) | Renovate | disk, logs, secrets |
| Docker Hub access token | GitHub environment secret (`dockerhub`) | the publish job only | repo-level secrets, workflow files, logs |
| Docker Hub username, App ID, Installation ID | plain variables (not sensitive) | workflow and job | n/a |

Rules that make this hold:

- **Secret Manager**: the key is uploaded as a file, accessed only by the job service account through a resource-scoped Secret Accessor role. Enable Data Access audit logs for Secret Manager if you want a record of every read. Delete the local `.pem` after upload and never commit it (`.gitignore` and `.dockerignore` exclude `*.pem`).
- **GitHub environment**: the Docker Hub token is only available to the `publish` job, only on the `main` branch, optionally after manual approval. Pull requests, forks and other branches cannot read it.
- **Least privilege Docker Hub token**: scope the access token to the single repository, with Read & Write.
- **Workflow hardening**: default `contents: read` permissions, `persist-credentials: false` on checkout, all actions pinned to commit SHAs, and secrets are only passed through `with:` inputs of the official Docker actions, never interpolated into shell scripts. Use `pull_request`, not `pull_request_target`, so fork code never runs with secrets.
- **GitHub repo settings**: under Settings > Actions > General set "Fork pull request workflows" to require approval, and keep workflow permissions at read-only by default. Enable secret scanning and push protection (free on public repos).
- **No secrets in logs**: `generate-token.js` prints only the HTTP status and GitHub's message on failure. Do not enable shell tracing (`set -x`) or `LOG_LEVEL=trace` in production. GitHub masks registered secrets in Actions logs, but masking is a safety net, not a control.
- **Cloud Run Job configuration**: no secret appears in the job's environment variables. The only secret reference is the mounted volume. Anyone with job view access sees a reference to the secret, not its value.
- **Image integrity**: the base image is pinned by digest, and the job should run the published image by digest.
- **GitHub App**: install it only on the repositories Renovate manages. Contents write access is powerful, so protect the app owner account with two-factor authentication.
- **Rotation**: rotate the GitHub App key and the Docker Hub token periodically, or immediately if exposed. For the app key, generate a new key in the app settings, add a new Secret Manager version, then delete the old key and disable the old version. The job mounts `latest`, so the next run picks it up.

If a secret is ever exposed, revoke it at the source first (delete the GitHub App key, delete the Docker Hub token), then replace it. Removing it from git history is not enough.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `cannot read private key` | Secret volume not mounted at `/secrets` with path `app-key.pem`, or the job service account lacks Secret Accessor |
| `GitHub API returned 401` | Wrong `APP_ID`, or the key does not belong to that app |
| `GitHub API returned 404` | Wrong `INSTALLATION_ID`, or the app is not installed on the account |
| Scheduler returns 403 | Scheduler service account lacks Cloud Run Invoker on the job |
| `exec format error` | Image built for the wrong architecture, rebuild with `linux/amd64` |
| Out-of-memory kill | Raise job memory to 4 GiB |
| No pull requests appear | Check `RENOVATE_REPOSITORIES` or autodiscover, app permissions, and the job logs |
| Commits show the wrong author | Set `RENOVATE_GIT_AUTHOR` with the bot's numeric ID |

## Repository layout

| File | Purpose |
|---|---|
| `Dockerfile` | Pinned Renovate base image plus the two scripts |
| `entrypoint.sh` | Generates the token (unless provided) and starts Renovate |
| `generate-token.js` | Creates the GitHub App JWT and exchanges it for an installation token |
| `.github/workflows/build.yml` | Builds and publishes the image |
| `renovate.json` | Keeps the base image and actions up to date |

## License

MIT, see [LICENSE](LICENSE).
