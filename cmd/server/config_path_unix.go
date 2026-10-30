//go:build !windows

package main

// defaultConfigPath keeps the existing portable layout on Unix-like systems.
func defaultConfigPath() string { return "config.json" }

// resolveManagedConfigPaths is intentionally a no-op outside Windows. Relative
// paths have historically been resolved from the process working directory on
// these platforms and changing that would break existing deployments.
func resolveManagedConfigPaths(_ *Config, _ string) {}
