# DCM Shared Workflows

Reusable GitHub Actions workflows for DCM project repositories.

## Available Workflows

| Workflow | Description | Usage |
|----------|-------------|-------|
| `go-ci.yaml` | Build and test Go projects | All Go repos |
| `check-aep.yaml` | Validate OpenAPI specs against AEP standards | Repos with OpenAPI |
| `check-generate.yaml` | Verify generated files are in sync | Repos with code generation |
| `check-clean-commits.yaml` | Ensure PR commits are cleaned before merge | All repos |
| `build-push-quay.yaml` | Build container image and push to Quay.io | Manager repos (Containerfile) |
| `tag-release.yaml` | Git-tag all service repos with a release or RC version | shared-workflows (manual dispatch) |
| `gateway-contract-test.yaml` | Validate KrakenD gateway routes against backend OpenAPI specs | api-gateway and backend repos |

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

Use `build-push-quay.yaml` from manager repos that have a `Containerfile`. Create `.github/workflows/build-push-quay.yaml`:

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
      image-name: service-provider-manager
      version: ${{ github.event.inputs.version }}
    secrets:
      quay-username: ${{ secrets.QUAY_USERNAME }}
      quay-password: ${{ secrets.QUAY_PASSWORD }}
```

#### Tag behavior

| Trigger | Image tags | Example |
|---|---|---|
| Push to `main` | `main`, `<short-sha>` | `:main`, `:a6882f7` |
| Push to `release/v*` branch | `<short-sha>` | `:a6882f7` |
| Push of `v*` git tag | `<short-sha>`, tag name | `:a6882f7`, `:v0.0.1`, `:v0.0.1-rc.1` |
| Manual dispatch with `version` | Only the specified tag | `:v0.0.1` |

`main` tag is only produced by pushes to the `main` branch. Version branch and git tag pushes do not update it.

#### Release flow

1. **Development happens on `main`** -- every merge triggers a build tagged `main` and `<short-sha>`.

2. **Create a release branch** prefixed with `release/`:
   ```bash
   git checkout -b release/v0.0.1
   git push -u origin release/v0.0.1
   ```

3. **Push fixes** to the release branch. Each push triggers CI, producing a `<short-sha>` image:
   ```bash
   git checkout release/v0.0.1
   # ... commit fixes ...
   git push origin release/v0.0.1
   ```

4. **(Optional) Tag a release candidate**. Use the [script](https://github.com/dcm-project/shared-workflows/blob/main/hack/tag-release.sh) 
   to git-tag all service repos at once from their release branch HEAD:
   ```bash
   ./hack/tag-release.sh v0.0.1-rc.1
   ```
   Each git tag push triggers CI, which builds the image with tags `v0.0.1-rc.1` and `<short-sha>`.

5. **QE validates** against the RC tag. If issues are found, 
   push fixes to the release branch (step 3) and cut the next RC (step 4).

6. **Tag the final release** on the approved commit using the same script:
   ```bash
   ./hack/tag-release.sh v0.0.1
   ```
   CI builds the image with tags `v0.0.1` and `<short-sha>` for each service.

7. **Cherry-pick** bug fixes from the release branch into `main` (if not already in main),
   so that issues caught during stabilization are propagated into main.

8. **For the next release**, create a new branch (e.g. `release/v0.0.2` or `release/v0.1.0`) and repeat from step 2.

#### Version convention

Follow [Semantic Versioning](https://semver.org/): `vMAJOR.MINOR.PATCH` (e.g. `v0.0.1`, `v1.2.0`). 
All version identifiers must start with `v`. Release branches use the `release/` prefix (e.g. `release/v0.0.1`). 
Both release candidates (`v0.0.1-rc.1`) and final releases (`v0.0.1`) are git-tagged.

**Required secrets:** `QUAY_USERNAME`, `QUAY_PASSWORD` (org or repo level). Default registry is `quay.io/dcm-project`. Images are built for `linux/amd64` and `linux/arm64`; override with the `platforms` input if needed.

#### Release tagging

Use `tag-release.yaml` to git-tag all service repos at once from their release branch HEAD.
Each tag push triggers CI, which builds and pushes the image. This works for both RC tags and final releases.

**GitHub workflow** -- trigger via the Actions UI (shared-workflows -> Actions -> "Tag Release" -> Run workflow) or the CLI:

```bash
gh workflow run tag-release.yaml --repo dcm-project/shared-workflows \
  -f tag=v0.0.1-rc.1

gh workflow run tag-release.yaml --repo dcm-project/shared-workflows \
  -f tag=v0.0.1-rc.2 \
  -f services="placement-manager catalog-manager"

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
./hack/tag-release.sh v0.0.1-rc.2 placement-manager catalog-manager  # specific services only
./hack/tag-release.sh v0.0.1                                # final release
```

The script resolves the HEAD of the release branch (derived from the tag: `v0.0.1-rc.1` or `v0.0.1` -> branch `release/v0.0.1`) 
for each service repo via `gh api`, creates an annotated git tag at that commit, and pushes it.

### Gateway contract test

Use `gateway-contract-test.yaml` from the **api-gateway** repo to validate that KrakenD routes match backend OpenAPI specs, and from **manager** repos to validate that a service's OpenAPI spec is covered by the gateway. The gateway's `krakend.json` must define `x-contract-specs`.

**x-contract-specs** is a top-level key in the KrakenD config (e.g. `config/krakend.json`). It is an object mapping backend hostname (as used in gateway routes) to `{ "openapi_url": "https://..." }`. The script loads each spec from `openapi_url` and checks that every backend route's method and path exists in the corresponding spec. Example:

```json
"x-contract-specs": {
  "service-provider-manager": {
    "openapi_url": "https://raw.githubusercontent.com/dcm-project/service-provider-manager/main/api/v1alpha1/openapi.yaml"
  },
  "catalog-manager": {
    "openapi_url": "https://raw.githubusercontent.com/dcm-project/catalog-manager/main/api/v1alpha1/openapi.yaml"
  }
}
```

**Gateway repo:** In the repo that owns `krakend.json` (e.g. api-gateway), add a job to `.github/workflows/ci.yaml`:

```yaml
gateway-contract-test:
  name: Gateway Contract Test
  uses: dcm-project/shared-workflows/.github/workflows/gateway-contract-test.yaml@main
  with:
    warn-uncovered: true
    watch-paths: |
      config/krakend.json
      config/krakend.json.tmpl
```

Use `warn-uncovered: true` to warn when the spec defines paths that no gateway route uses.

**Manager repo:** In a backend/manager repo that exposes an OpenAPI spec and is wired in the gateway's `x-contract-specs`, create `.github/workflows/gateway-contract-test.yaml` (or add a job to CI) that calls the shared workflow with `krakend-repo` set to the gateway repo and `override-spec` so this repo's OpenAPI file is used for that service. Run on PRs when `api/**/openapi.yaml` (or equivalent) changes:

```yaml
name: Gateway Contract Test
on:
  pull_request:
    branches: [main]

jobs:
  contract-test:
    uses: dcm-project/shared-workflows/.github/workflows/gateway-contract-test.yaml@main
    with:
      krakend-repo: dcm-project/api-gateway
      krakend-config: config/krakend.json
      override-spec: service-provider-manager=api/v1alpha1/openapi.yaml
      service: service-provider-manager
      watch-paths: |
        api/**/openapi.yaml
```

`override-spec` is `hostname=path/to/openapi.yaml` (path relative to the manager repo root). `service` limits validation to that backend.

**Key inputs:** `krakend-repo`, `krakend-config`, `override-spec`, `service`, `warn-uncovered`, `watch-paths`. See the workflow file for the full list.

