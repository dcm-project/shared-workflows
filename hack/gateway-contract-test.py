#!/usr/bin/env python3
"""Validate KrakenD backend routes against upstream OpenAPI specs."""

import argparse
import json
import re
import sys
from dataclasses import dataclass
from urllib.parse import urlparse
from urllib.request import urlopen
from urllib.error import URLError

import yaml

HTTP_METHODS = {"get", "post", "put", "patch", "delete", "head", "options", "trace"}


def normalize_path(path: str) -> str:
    """Replace path parameters like {id} or {id:[0-9]+} with {_}."""
    return re.sub(r"\{[^}]*\}", "{_}", path)


def extract_hostname(url: str) -> str:
    """Extract hostname from a URL like http://service:8080/path."""
    parsed = urlparse(url)
    if parsed.hostname:
        return parsed.hostname
    return url


def extract_base_path(spec: dict) -> str:
    """Detect Swagger 2.0 vs OpenAPI 3.x and return the base path."""
    if spec.get("swagger"):
        base = spec.get("basePath", "")
        return base.rstrip("/")

    servers = spec.get("servers", [])
    if servers:
        server_url = servers[0].get("url", "")
        parsed = urlparse(server_url)
        if parsed.path:
            return parsed.path.rstrip("/")
    return ""


def parse_spec(spec: dict, verbose: bool = False) -> tuple[set[str], set[str], int]:
    """Parse an OpenAPI/Swagger spec and return operations and paths.

    Returns:
        operations: set of "METHOD /normalized/path" strings
        all_paths: set of all normalized paths (for uncovered warnings)
        count: number of operations found
    """
    operations = set()
    all_paths = set()
    has_ref = False

    paths = spec.get("paths", {})
    if not paths:
        return operations, all_paths, 0

    base_path = extract_base_path(spec)

    for api_path, path_item in paths.items():
        if not isinstance(path_item, dict):
            continue
        for method, operation in path_item.items():
            if method == "$ref":
                has_ref = True
                continue
            if method.lower() not in HTTP_METHODS:
                continue

            full_path = f"{base_path}{api_path}" if base_path else api_path
            normalized = normalize_path(full_path)
            key = f"{method.upper()} {normalized}"

            operations.add(key)
            all_paths.add(normalized)

            if verbose:
                print(f"    spec: {key}")

    if has_ref:
        print("  WARN  spec contains unresolved $ref entries; results may be incomplete",
              file=sys.stderr)

    return operations, all_paths, len(operations)


def download_spec(url: str) -> dict:
    """Download and parse a spec from a URL."""
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https"):
        raise SystemExit(f"Error: unsupported URL scheme {parsed.scheme!r} in {url}")

    try:
        with urlopen(url, timeout=30) as response:
            data = response.read()
    except (URLError, OSError) as exc:
        raise SystemExit(f"Error: failed to download spec from {url}: {exc}") from exc

    return yaml.safe_load(data)


def load_spec(path: str) -> dict:
    """Load and parse a spec from a local file."""
    try:
        with open(path, encoding="utf-8") as f:
            return yaml.safe_load(f)
    except FileNotFoundError:
        raise SystemExit(f"Error: file not found: {path}")
    except yaml.YAMLError as exc:
        raise SystemExit(f"Error: invalid YAML in {path}: {exc}")


@dataclass
class BackendRoute:
    method: str
    path: str
    hostname: str


def extract_routes(config: dict, service_filter: str, verbose: bool) -> list[BackendRoute]:
    """Extract backend routes from KrakenD config."""
    routes = []

    for endpoint in config.get("endpoints", []):
        endpoint_method = endpoint.get("method", "")

        for backend in endpoint.get("backend", []):
            hosts = backend.get("host", [])
            url_pattern = backend.get("url_pattern", "")

            if not hosts:
                if verbose:
                    print(f"  WARN  backend {url_pattern} has no host defined; "
                          "skipping validation", file=sys.stderr)
                continue

            host_url = hosts[0]
            hostname = extract_hostname(host_url)

            if service_filter and hostname != service_filter:
                continue

            method = backend.get("method", "") or endpoint_method or "GET"
            if verbose and not backend.get("method") and not endpoint_method:
                print(f"  WARN  no method for backend {url_pattern}; defaulting to GET",
                      file=sys.stderr)

            routes.append(BackendRoute(
                method=method.upper(),
                path=url_pattern,
                hostname=hostname,
            ))

    return routes


@dataclass
class ValidationResult:
    method: str
    path: str
    hostname: str
    passed: bool
    reason: str = ""


def validate_routes(
    routes: list[BackendRoute],
    spec_ops: dict[str, set[str]],
    verbose: bool,
) -> tuple[list[ValidationResult], dict[str, set[str]]]:
    """Validate routes against spec operations.

    Returns:
        results: list of ValidationResult
        covered_paths: dict of service -> set of paths that were matched
    """
    results = []
    covered_paths: dict[str, set[str]] = {}

    for route in routes:
        if route.hostname not in spec_ops:
            results.append(ValidationResult(
                method=route.method,
                path=route.path,
                hostname=route.hostname,
                passed=False,
                reason=f"no spec configured for hostname {route.hostname!r}",
            ))
            continue

        if verbose and re.search(r"\{[^}]+:[^}]+\}", route.path):
            print(f'  WARN  path "{route.path}" contains regex parameter; '
                  "match may be unreliable", file=sys.stderr)

        normalized = normalize_path(route.path)
        lookup_key = f"{route.method} {normalized}"

        if lookup_key in spec_ops[route.hostname]:
            results.append(ValidationResult(
                method=route.method,
                path=route.path,
                hostname=route.hostname,
                passed=True,
            ))
            covered_paths.setdefault(route.hostname, set()).add(normalized)
        else:
            results.append(ValidationResult(
                method=route.method,
                path=route.path,
                hostname=route.hostname,
                passed=False,
                reason=f"not found in OpenAPI spec (expected key: {lookup_key})",
            ))

    return results, covered_paths


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="config/krakend.json",
                        help="Path to krakend config (default: config/krakend.json)")
    parser.add_argument("--warn-uncovered", action="store_true",
                        help="Warn about spec paths not covered by any backend route")
    parser.add_argument("--verbose", action="store_true", help="Verbose output")
    parser.add_argument("--service", default="",
                        help="Only validate routes for this service hostname")
    parser.add_argument("--override", action="append", default=[], metavar="HOST=PATH",
                        help="Override a service spec with local file (repeatable)")
    args = parser.parse_args()

    overrides = {}
    for override in args.override:
        if "=" not in override:
            print("Error: --override must be in format hostname=/path/to/spec.yaml", file=sys.stderr)
            return 2
        host, path = override.split("=", 1)
        if not host or not path:
            print("Error: --override must be in format hostname=/path/to/spec.yaml", file=sys.stderr)
            return 2
        overrides[host] = path

    # Load KrakenD config
    print("Contract Test: KrakenD vs OpenAPI Specs")
    print("========================================")

    try:
        with open(args.config) as f:
            config = json.load(f)
    except FileNotFoundError:
        print(f"Error: config file not found: {args.config}", file=sys.stderr)
        return 2
    except json.JSONDecodeError as exc:
        print(f"Error: invalid JSON in {args.config}: {exc}", file=sys.stderr)
        return 2

    contract_specs = config.get("x-contract-specs")
    if not contract_specs:
        print("Error: no x-contract-specs found in config", file=sys.stderr)
        return 2

    # Download and parse specs
    print("Downloading specs...")
    spec_ops: dict[str, set[str]] = {}
    spec_all_paths: dict[str, set[str]] = {}

    for svc_name in sorted(contract_specs.keys()):
        if args.service and svc_name != args.service:
            if args.verbose:
                print(f"  {svc_name}: skipped (filtering for {args.service})")
            continue

        if svc_name in overrides:
            print(f"  {svc_name}: loading from local file {overrides[svc_name]}")
            spec = load_spec(overrides[svc_name])
        else:
            spec_url = contract_specs[svc_name].get("openapi_url", "")
            if not spec_url:
                print(f"Error: service {svc_name}: openapi_url is empty", file=sys.stderr)
                return 2
            spec = download_spec(spec_url)

        if args.verbose:
            swagger_ver = spec.get("swagger")
            openapi_ver = spec.get("openapi")
            if swagger_ver:
                print(f"    detected: Swagger {swagger_ver}")
            elif openapi_ver:
                print(f"    detected: OpenAPI {openapi_ver}")

        operations, all_paths, count = parse_spec(spec, verbose=args.verbose)

        if count == 0:
            print(f"Error: service {svc_name}: spec contains no operations "
                  "(0 paths with HTTP methods)", file=sys.stderr)
            return 2

        spec_ops[svc_name] = operations
        spec_all_paths[svc_name] = all_paths
        print(f"  {svc_name}: OK ({count} operations)")

    # Extract and validate routes
    routes = extract_routes(config, args.service, args.verbose)

    print(f"\nValidating {len(routes)} backend routes...")

    results, covered_paths = validate_routes(routes, spec_ops, args.verbose)

    passed = 0
    failed = 0
    for result in results:
        if result.passed:
            print(f"  PASS  {result.method:<6} {result.path:<45} -> {result.hostname}")
            passed += 1
        else:
            print(f"  FAIL  {result.method:<6} {result.path:<45} -> {result.hostname}")
            print(f"        {result.reason}")
            failed += 1

    # Warn about uncovered paths
    if args.warn_uncovered:
        print()
        for svc_name in sorted(spec_all_paths.keys()):
            covered = covered_paths.get(svc_name, set())
            for path in sorted(spec_all_paths[svc_name] - covered):
                print(f"  WARN  spec path {path:<45} in {svc_name} "
                      "not covered by any gateway route")

    print()
    if failed > 0:
        print(f"Result: FAIL ({passed} passed, {failed} failed)")
        return 1
    print(f"Result: PASS ({passed} passed, {failed} failed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
