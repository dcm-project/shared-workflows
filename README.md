# DCM Shared Workflows

Reusable GitHub Actions workflows for DCM project repositories.

## Available Workflows

| Workflow | Description | Usage |
|----------|-------------|-------|
| `go-ci.yaml` | Build and test Go projects | All Go repos |
| `check-aep.yaml` | Validate OpenAPI specs against AEP standards | Repos with OpenAPI |
| `check-generate.yaml` | Verify generated files are in sync | Repos with code generation |
| `check-clean-commits.yaml` | Ensure PR commits are cleaned before merge | All repos |

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

## License

Apache 2.0 - See [LICENSE](LICENSE)
