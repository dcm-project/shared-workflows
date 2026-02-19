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

Use `build-push-quay.yaml` from manager repos that have a `Containerfile`. Add a workflow that runs on push to `main` (and optionally on version tags), and pass Quay credentials as secrets:

```yaml
# .github/workflows/build-push.yaml
name: Build and Push Image
on:
  push:
    branches: [main]
    tags: ['v*']

jobs:
  build-push:
    uses: dcm-project/shared-workflows/.github/workflows/build-push-quay.yaml@quay-publish
    with:
      image-name: service-provider-manager
      tags: ${{ github.ref_name }}
    secrets:
      quay-username: ${{ secrets.QUAY_USERNAME }}
      quay-password: ${{ secrets.QUAY_PASSWORD }}
```

**Required secrets** (in the calling repo or org): `QUAY_USERNAME`, `QUAY_PASSWORD`. For a [Quay robot account](https://docs.quay.io/glossary/robot-accounts.html): set `QUAY_USERNAME` to the robot name (e.g. `dcm-project+ci-push`) and `QUAY_PASSWORD` to the robot token; the example above is unchanged. Default registry is `quay.io/dcm-project`. To override (e.g. use another Quay org or a user namespace), pass the `registry` input:

```yaml
    with:
      image-name: service-provider-manager
      registry: quay.io/your-org-or-username
      tags: ${{ github.ref_name }}
```

## License

Apache 2.0 - See [LICENSE](LICENSE)
