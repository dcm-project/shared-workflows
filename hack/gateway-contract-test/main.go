package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strings"

	"gopkg.in/yaml.v3"
)

// KrakenD config (partial)
type KrakenDConfig struct {
	Endpoints     []Endpoint             `json:"endpoints"`
	ContractSpecs map[string]ContractSpec `json:"x-contract-specs"`
}

type Endpoint struct {
	Path    string    `json:"endpoint"`
	Method  string    `json:"method"`
	Backend []Backend `json:"backend"`
}

type Backend struct {
	URLPattern string   `json:"url_pattern"`
	Method     string   `json:"method"`
	Host       []string `json:"host"`
}

type ContractSpec struct {
	OpenAPIURL string `json:"openapi_url"`
}

// OpenAPI spec (partial)
type OpenAPISpec struct {
	Servers []Server                          `yaml:"servers"`
	Paths   map[string]map[string]interface{} `yaml:"paths"`
}

type Server struct {
	URL string `yaml:"url"`
}

// backendRoute is an extracted route from KrakenD config
type backendRoute struct {
	method   string
	path     string
	hostname string
}

var paramRe = regexp.MustCompile(`\{[^}]+\}`)

func normalizePath(p string) string {
	return paramRe.ReplaceAllString(p, "{_}")
}

func extractHostname(hostURL string) string {
	u, err := url.Parse(hostURL)
	if err != nil {
		return hostURL
	}
	return u.Hostname()
}

func main() {
	configPath := flag.String("config", "config/krakend.json", "path to krakend.json")
	warnUncovered := flag.Bool("warn-uncovered", false, "warn about spec paths not covered by any backend route")
	includeHealth := flag.Bool("include-health", false, "include health check routes in validation")
	verbose := flag.Bool("verbose", false, "verbose output")
	override := flag.String("override", "", "override a service spec with local file: hostname=/path/to/spec.yaml")
	service := flag.String("service", "", "only validate routes for this service hostname")
	flag.Parse()

	// Parse override flag
	var overrideHost, overridePath string
	if *override != "" {
		parts := strings.SplitN(*override, "=", 2)
		if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
			fmt.Fprintf(os.Stderr, "Error: -override must be in format hostname=/path/to/spec.yaml\n")
			os.Exit(2)
		}
		overrideHost = parts[0]
		overridePath = parts[1]
	}

	data, err := os.ReadFile(*configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error reading config: %v\n", err)
		os.Exit(2)
	}

	var cfg KrakenDConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		fmt.Fprintf(os.Stderr, "Error parsing config: %v\n", err)
		os.Exit(2)
	}

	if len(cfg.ContractSpecs) == 0 {
		fmt.Fprintf(os.Stderr, "Error: no x-contract-specs found in config\n")
		os.Exit(2)
	}

	fmt.Println("Contract Test: KrakenD vs OpenAPI Specs")
	fmt.Println("========================================")

	// Download and parse specs
	fmt.Println("Downloading specs...")
	specOps := make(map[string]map[string]bool)
	specAllPaths := make(map[string]map[string]bool)

	for name, spec := range cfg.ContractSpecs {
		// If -service is set, skip hostnames that don't match
		if *service != "" && name != *service {
			if *verbose {
				fmt.Printf("  %s: skipped (filtering for %s)\n", name, *service)
			}
			continue
		}

		var ops map[string]bool
		var allPaths map[string]bool
		var opCount int

		if overrideHost == name {
			fmt.Printf("  %s: loading from local file %s\n", name, overridePath)
			ops, allPaths, opCount, err = loadAndParseSpec(overridePath, *verbose)
		} else {
			ops, allPaths, opCount, err = downloadAndParseSpec(spec.OpenAPIURL, *verbose)
		}
		if err != nil {
			fmt.Fprintf(os.Stderr, "  %s: FAILED (%v)\n", name, err)
			os.Exit(2)
		}
		fmt.Printf("  %s: OK (%d operations)\n", name, opCount)
		specOps[name] = ops
		specAllPaths[name] = allPaths
	}

	// Extract backend routes
	var routes []backendRoute
	healthSkipped := 0
	for _, ep := range cfg.Endpoints {
		for _, b := range ep.Backend {
			if !*includeHealth && strings.HasSuffix(b.URLPattern, "/health") {
				healthSkipped++
				continue
			}
			hostname := ""
			if len(b.Host) > 0 {
				hostname = extractHostname(b.Host[0])
			}

			// If -service is set, skip routes for other hostnames
			if *service != "" && hostname != *service {
				continue
			}

			method := b.Method
			if method == "" {
				method = ep.Method
			}
			routes = append(routes, backendRoute{
				method:   strings.ToUpper(method),
				path:     b.URLPattern,
				hostname: hostname,
			})
		}
	}

	skipMsg := ""
	if healthSkipped > 0 {
		skipMsg = fmt.Sprintf(" (%d health routes skipped)", healthSkipped)
	}
	fmt.Printf("\nValidating %d backend routes%s...\n", len(routes), skipMsg)

	passed := 0
	failed := 0

	// Track which spec paths are covered
	coveredPaths := make(map[string]map[string]bool)
	for name := range specOps {
		coveredPaths[name] = make(map[string]bool)
	}

	for _, r := range routes {
		ops, ok := specOps[r.hostname]
		if !ok {
			fmt.Printf("  FAIL  %-6s %-45s -> %s\n", r.method, r.path, r.hostname)
			fmt.Printf("        no spec configured for hostname %q\n", r.hostname)
			failed++
			continue
		}

		normalizedPath := normalizePath(r.path)
		key := r.method + " " + normalizedPath
		if ops[key] {
			fmt.Printf("  PASS  %-6s %-45s -> %s\n", r.method, r.path, r.hostname)
			passed++
			coveredPaths[r.hostname][normalizedPath] = true
		} else {
			fmt.Printf("  FAIL  %-6s %-45s -> %s\n", r.method, r.path, r.hostname)
			fmt.Printf("        not found in OpenAPI spec\n")
			failed++
		}
	}

	// Warn about uncovered spec paths
	if *warnUncovered {
		fmt.Println()
		for name, paths := range specAllPaths {
			covered := coveredPaths[name]
			for path := range paths {
				if !covered[path] {
					fmt.Printf("  WARN  spec path %-45s in %s not covered by any gateway route\n", path, name)
				}
			}
		}
	}

	fmt.Println()
	if failed > 0 {
		fmt.Printf("Result: FAIL (%d passed, %d failed)\n", passed, failed)
		os.Exit(1)
	}
	fmt.Printf("Result: PASS (%d passed, %d failed)\n", passed, failed)
}

// parseSpec parses OpenAPI YAML bytes and returns operations and paths.
func parseSpec(data []byte, verbose bool) (map[string]bool, map[string]bool, int, error) {
	var spec OpenAPISpec
	if err := yaml.Unmarshal(data, &spec); err != nil {
		return nil, nil, 0, fmt.Errorf("parse YAML: %w", err)
	}

	// Determine base path from servers[0].url
	basePath := ""
	if len(spec.Servers) > 0 {
		serverURL := spec.Servers[0].URL
		if strings.HasPrefix(serverURL, "http://") || strings.HasPrefix(serverURL, "https://") {
			if u, err := url.Parse(serverURL); err == nil {
				basePath = strings.TrimSuffix(u.Path, "/")
			}
		} else {
			basePath = strings.TrimSuffix(serverURL, "/")
		}
	}

	if verbose && basePath != "" {
		fmt.Printf("    base path: %s\n", basePath)
	}

	httpMethods := map[string]bool{
		"get": true, "post": true, "put": true, "patch": true,
		"delete": true, "head": true, "options": true, "trace": true,
	}

	ops := make(map[string]bool)
	allPaths := make(map[string]bool)
	opCount := 0

	for path, methods := range spec.Paths {
		fullPath := basePath + path
		normalizedPath := normalizePath(fullPath)
		allPaths[normalizedPath] = true

		for method := range methods {
			if !httpMethods[strings.ToLower(method)] {
				continue
			}
			key := strings.ToUpper(method) + " " + normalizedPath
			ops[key] = true
			opCount++

			if verbose {
				fmt.Printf("    spec: %s\n", key)
			}
		}
	}

	return ops, allPaths, opCount, nil
}

// downloadAndParseSpec fetches an OpenAPI spec from a URL.
func downloadAndParseSpec(specURL string, verbose bool) (map[string]bool, map[string]bool, int, error) {
	resp, err := http.Get(specURL)
	if err != nil {
		return nil, nil, 0, fmt.Errorf("download failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return nil, nil, 0, fmt.Errorf("HTTP %d from %s", resp.StatusCode, specURL)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, nil, 0, fmt.Errorf("read body: %w", err)
	}

	return parseSpec(body, verbose)
}

// loadAndParseSpec reads an OpenAPI spec from a local file.
func loadAndParseSpec(path string, verbose bool) (map[string]bool, map[string]bool, int, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, nil, 0, fmt.Errorf("read file: %w", err)
	}

	return parseSpec(data, verbose)
}
