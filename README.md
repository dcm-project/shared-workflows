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
    branches: [main]
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
| Push to `main` | `latest`, `sha-<7chars>` | `:latest`, `:sha-abc1234` |
| Push to `release/v*` branch | Value from `VERSION` file, `<short-sha>` | `:v0.0.1-rc.3`, `:a6882f7` |
| Push of `v*` git tag | `latest`, `sha-<7chars>`, tag name | `:latest`, `:sha-abc1234`, `:v0.0.1` |
| Manual dispatch with `version` | Only the specified tag | `:v0.0.1` |

#### Release candidate (RC) flow

For `release/v*` branches, the workflow reads a `VERSION` file from the repo root and uses its content
as an image tag (alongside the short commit SHA). This supports an RC workflow:

1. Create a `release/v*` branch and add or update the `VERSION` file (e.g. `v0.0.1-rc.1`)
2. Each push rebuilds the image with the tag from `VERSION` + the commit SHA
3. Bump the `VERSION` file for each new RC (`v0.0.1-rc.2`, `v0.0.1-rc.3`, ...)
4. After QE approval, create a git tag (`v0.0.1`) on the approved commit for the final release

The `VERSION` file is required on `release/v*` branches -- the build will fail if it is missing or empty.

Callers must include `'release/v*'` in their branch triggers to enable this:

```yaml
on:
  push:
    branches: [main, 'release/v*']
    tags: ['v*']
```

**Required secrets:** `QUAY_USERNAME`, `QUAY_PASSWORD` (org or repo level). Default registry is `quay.io/dcm-project`. Images are built for `linux/amd64` and `linux/arm64`; override with the `platforms` input if needed.

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

