# DCM Shared Workflows

Reusable GitHub Actions workflows for DCM project repositories.

## Available Workflows

| Workflow | Description | Usage |
|----------|-------------|-------|
| `go-ci.yaml` | Build and test Go projects | All Go repos |
| `check-aep.yaml` | Validate OpenAPI specs against AEP standards | Repos with OpenAPI |
| `check-generate.yaml` | Verify generated files are in sync | Repos with code generation |
| `check-clean-commits.yaml` | Ensure PR commits are cleaned before merge | All repos |
| `build-push-quay.yaml` | Build container image and push to Quay.io | `dcm-project` repos with a Containerfile |
| `tag-release.yaml` | Git-tag all service repos with a release or RC version | shared-workflows (manual dispatch) |
| `gitleaks.yaml` | Scan for leaked secrets using gitleaks | All repos |

## Usage

In your repository, create a workflow file that calls a shared workflow:

```yaml
# .github/workflows/ci.yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  ci:
    uses: dcm-project/shared-workflows/.github/workflows/<workflow>.yaml@main
```

See individual workflow files for available options and inputs.

### Build and push to Quay.io

Use `build-push-quay.yaml` from `dcm-project` repos that have a `Containerfile`. Create
`.github/workflows/build-push-quay.yaml`:

```yaml
name: Build and Push Image
on:
  push:
    branches: [main, 'release/v*']
    tags: ['v*']
  workflow_dispatch:
    inputs:
      version:
        description: 'Version tag to push (e.g. v1.0.0). When set, only this tag is used.'
        required: false

jobs:
  build-push:
    uses: dcm-project/shared-workflows/.github/workflows/build-push-quay.yaml@main
    with:
      image-name: control-plane
      version: ${{ github.event.inputs.version }}
    secrets:
      quay-username: ${{ secrets.QUAY_USERNAME }}
      quay-password: ${{ secrets.QUAY_TOKEN }}
```

#### Tag behavior

| Trigger | Image tags | Example |
|---|---|---|
| Push to `main` | `main`, `<short-sha>` | `:main`, `:a6882f7` |
| Push to `release/v*` branch | `<short-sha>` | `:a6882f7` |
| Push of `v*` git tag | `<short-sha>`, tag name | `:a6882f7`, `:v0.0.1`, `:v0.0.1-rc.1` |
| Manual dispatch with `version` | Only the specified tag | `:v0.0.1` |

`main` tag is only produced by pushes to the `main` branch. Version branch and
git tag pushes do not update it.

#### Release flow

1. **Development happens on `main`** -- every merge triggers a build tagged
   `main` and `<short-sha>`.

2. **Create a release branch** prefixed with `release/`:
   ```bash
   git checkout -b release/v0.0.1
   git push -u origin release/v0.0.1
   ```

3. **Push fixes** to the release branch. Each push triggers CI, producing a
   `<short-sha>` image:
   ```bash
   git checkout release/v0.0.1
   # ... commit fixes ...
   git push origin release/v0.0.1
   ```

4. **(Optional) Tag a release candidate**. Use the
   [script](https://github.com/dcm-project/shared-workflows/blob/main/hack/tag-release.sh)
   to git-tag all service repos at once from their release branch HEAD:
   ```bash
   ./hack/tag-release.sh v0.0.1-rc.1
   ```
   Each git tag push triggers CI, which builds the image with tags `v0.0.1-rc.1`
   and `<short-sha>`.

5. **QE validates** against the RC tag. If issues are found, push fixes to the
   release branch (step 3) and cut the next RC (step 4).

6. **Tag the final release** on the approved commit using the same script:
   ```bash
   ./hack/tag-release.sh v0.0.1
   ```
   CI builds the image with tags `v0.0.1` and `<short-sha>` for each service.

7. **Cherry-pick** bug fixes from the release branch into `main` (if not already
   in main), so that issues caught during stabilization are propagated into
   main.

8. **For the next release**, create a new branch (e.g. `release/v0.0.2` or
   `release/v0.1.0`) and repeat from step 2.

#### Version convention

Follow [Semantic Versioning](https://semver.org/): `vMAJOR.MINOR.PATCH` (e.g.
`v0.0.1`, `v1.2.0`). All version identifiers must start with `v`. Release
branches use the `release/` prefix (e.g. `release/v0.0.1`). Both release
candidates (`v0.0.1-rc.1`) and final releases (`v0.0.1`) are git-tagged.

**Required secrets:** `QUAY_USERNAME`, `QUAY_TOKEN` (org or repo level).
`QUAY_TOKEN` is the Quay password for that account (robot token or user
password). Map both to the workflow `quay-username` and `quay-password`
inputs as in the example above.
Default registry is `quay.io/dcm-project`. Images are built for `linux/amd64`
and `linux/arm64`; override with the `platforms` input if needed.

#### Release tagging

Use `tag-release.yaml` to git-tag all service repos at once from their release
branch HEAD. Each tag push triggers CI, which builds and pushes the image. This
works for both RC tags and final releases.

**GitHub workflow** -- trigger via the Actions UI (shared-workflows -> Actions
-> "Tag Release" -> Run workflow) or the CLI:

```bash
gh workflow run tag-release.yaml --repo dcm-project/shared-workflows \
  -f tag=v0.0.1-rc.1

gh workflow run tag-release.yaml --repo dcm-project/shared-workflows \
  -f tag=v0.0.1-rc.2 \
  -f services="control-plane"

gh workflow run tag-release.yaml --repo dcm-project/shared-workflows \
  -f tag=v0.0.1
```

| Input | Required | Description |
|---|---|---|
| `tag` | Yes | Version tag to create (e.g. `v0.0.1-rc.1` or `v0.0.1`) |
| `services` | No | Space-separated services to tag (default: all DCM services) |

**Local script** (`hack/tag-release.sh` in this repo):

```bash
./hack/tag-release.sh v0.0.1-rc.1                          # tag all services
./hack/tag-release.sh v0.0.1-rc.2 control-plane              # specific services only
./hack/tag-release.sh v0.0.1                                # final release
```

The script resolves the HEAD of the release branch (derived from the tag:
`v0.0.1-rc.1` or `v0.0.1` -> branch `release/v0.0.1`) for each service repo via
`gh api`, creates an annotated git tag at that commit, and pushes it.

### Gitleaks secret scanning

Use `gitleaks.yaml` to scan for leaked secrets. It supports three scan modes:
**diff** (PR commits), **push** (pushed commits), and **full** (entire history).
Results are reported in SARIF format and uploaded to GitHub Code Scanning by
default, so findings appear in the repository Security tab and as inline PR
annotations.

**Pull request scanning** -- create `.github/workflows/gitleaks.yaml`:

```yaml
name: Gitleaks
on:
  pull_request:
    branches: [main]

jobs:
  gitleaks:
    uses: dcm-project/shared-workflows/.github/workflows/gitleaks.yaml@main
    permissions:
      contents: read
      security-events: write
    with:
      scan-mode: diff
      base-sha: ${{ github.event.pull_request.base.sha }}
      head-sha: ${{ github.event.pull_request.head.sha }}
```

**Push scanning:**

```yaml
name: Gitleaks
on:
  push:
    branches: [main]

jobs:
  gitleaks:
    uses: dcm-project/shared-workflows/.github/workflows/gitleaks.yaml@main
    permissions:
      contents: read
      security-events: write
    with:
      scan-mode: push
      base-sha: ${{ github.event.before }}
      head-sha: ${{ github.sha }}
```

| Input | Type | Default | Description |
|---|---|---|---|
| `scan-mode` | string | *(required)* | `diff`, `push`, or `full` |
| `base-sha` | string | `''` | Start of commit range (required for diff/push) |
| `head-sha` | string | `''` | End of commit range (required for diff/push) |
| `go-version-file` | string | `''` | Path to go.mod for Go version (leave empty for non-Go repos; defaults to Go 1.25.5) |
| `config-path` | string | `''` | Path to a repo-specific `.gitleaks.toml` |
| `upload-sarif` | boolean | `true` | Upload SARIF to GitHub Code Scanning |
| `artifact-name` | string | `'gitleaks-report'` | Artifact name when `upload-sarif` is false |
| `artifact-retention-days` | number | `90` | Artifact retention in days |

**Custom config:** To override gitleaks rules, add a `.gitleaks.toml` to your
repo and pass its path via `config-path`. When empty, gitleaks uses its built-in
ruleset.

**SARIF integration:** Results use
[SARIF](https://docs.github.com/en/code-security/code-scanning/integrating-with-code-scanning/sarif-support-for-code-scanning)
format and are uploaded to GitHub Code Scanning via
`github/codeql-action/upload-sarif@v4`. This makes findings visible in the
repository's Security tab and as inline PR annotations, consistent with other
GitHub security tooling. For full-history scans, set `upload-sarif: false` to
download the report as a workflow artifact instead.

