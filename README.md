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

The shared workflow auto-computes tags (latest, sha-xxx, version on tag push). When `version` is passed (manual trigger), only that tag is pushed.

**Required secrets:** `QUAY_USERNAME`, `QUAY_PASSWORD` (org or repo level). Default registry is `quay.io/dcm-project`. Images are built for `linux/amd64` and `linux/arm64`; override with the `platforms` input if needed.

