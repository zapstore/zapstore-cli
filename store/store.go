// Package store manages local state and paths following the XDG Base Directory spec.
//
// Data layout (XDG_DATA_HOME, default ~/.local/share/zapstore):
//
//	packages/<app-id>/<version>/<binary>   ← actual files
//	bin/<binary>                           ← symlinks
//
// State (XDG_STATE_HOME, default ~/.local/state/zapstore):
//
//	state.json                             ← installed package metadata
//
// Legacy path ~/.zapstore is migrated automatically on first use.
package store

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// Package represents an installed package.
type Package struct {
	Pubkey       string   `json:"pubkey"`
	Version      string   `json:"version"`
	InstalledAt  string   `json:"installed_at"`
	Executables  []string `json:"executables"`
	AssetEventID string   `json:"asset_event_id"`
}

// State represents the full contents of state.json.
type State struct {
	Packages map[string]*Package `json:"packages"`
}

// DataDir returns the zapstore data directory.
// Respects XDG_DATA_HOME; defaults to ~/.local/share/zapstore.
func DataDir() (string, error) {
	if xdg := os.Getenv("XDG_DATA_HOME"); xdg != "" {
		return filepath.Join(xdg, "zapstore"), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("cannot determine home directory: %w", err)
	}
	return filepath.Join(home, ".local", "share", "zapstore"), nil
}

// StateDir returns the zapstore state directory.
// Respects XDG_STATE_HOME; defaults to ~/.local/state/zapstore.
func StateDir() (string, error) {
	if xdg := os.Getenv("XDG_STATE_HOME"); xdg != "" {
		return filepath.Join(xdg, "zapstore"), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("cannot determine home directory: %w", err)
	}
	return filepath.Join(home, ".local", "state", "zapstore"), nil
}

// BinDir returns the path to ~/.local/share/zapstore/bin.
func BinDir() (string, error) {
	d, err := DataDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(d, "bin"), nil
}

// legacyDir returns the old ~/.zapstore path.
func legacyDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".zapstore"), nil
}

// MigrateIfNeeded moves data from ~/.zapstore to XDG paths if the legacy
// directory exists and the new data directory does not.
func MigrateIfNeeded() error {
	legacy, err := legacyDir()
	if err != nil {
		return err
	}
	if _, err := os.Stat(legacy); os.IsNotExist(err) {
		return nil // nothing to migrate
	}

	dataDir, err := DataDir()
	if err != nil {
		return err
	}
	// If data dir already exists, skip migration
	if _, err := os.Stat(dataDir); err == nil {
		return nil
	}

	stateDir, err := StateDir()
	if err != nil {
		return err
	}

	// Ensure parent directories exist
	if err := os.MkdirAll(filepath.Dir(dataDir), 0o755); err != nil {
		return fmt.Errorf("creating data parent dir: %w", err)
	}
	if err := os.MkdirAll(stateDir, 0o755); err != nil {
		return fmt.Errorf("creating state dir: %w", err)
	}

	// Move state.json to state dir
	oldState := filepath.Join(legacy, "state.json")
	if _, err := os.Stat(oldState); err == nil {
		newState := filepath.Join(stateDir, "state.json")
		if err := os.Rename(oldState, newState); err != nil {
			return fmt.Errorf("migrating state.json: %w", err)
		}
	}

	// Move the rest (packages/, bin/) as the data dir
	if err := os.Rename(legacy, dataDir); err != nil {
		return fmt.Errorf("migrating data directory: %w", err)
	}

	fmt.Printf("Migrated ~/.zapstore → %s\n", dataDir)
	return nil
}

// statePath returns the path to state.json.
func statePath() (string, error) {
	dir, err := StateDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "state.json"), nil
}

// Load reads the current state from disk. Returns an empty state if the
// file does not exist.
func Load() (*State, error) {
	p, err := statePath()
	if err != nil {
		return nil, err
	}

	data, err := os.ReadFile(p)
	if err != nil {
		if os.IsNotExist(err) {
			return &State{Packages: make(map[string]*Package)}, nil
		}
		return nil, fmt.Errorf("reading state: %w", err)
	}

	var s State
	if err := json.Unmarshal(data, &s); err != nil {
		return nil, fmt.Errorf("parsing state: %w", err)
	}
	if s.Packages == nil {
		s.Packages = make(map[string]*Package)
	}
	return &s, nil
}

// Save writes the state to disk, creating the directory if needed.
func (s *State) Save() error {
	p, err := statePath()
	if err != nil {
		return err
	}

	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return fmt.Errorf("creating state directory: %w", err)
	}

	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return fmt.Errorf("marshaling state: %w", err)
	}

	return os.WriteFile(p, data, 0o644)
}

// Add records a newly installed package.
func (s *State) Add(appID string, pkg *Package) {
	if pkg.InstalledAt == "" {
		pkg.InstalledAt = time.Now().UTC().Format(time.RFC3339)
	}
	s.Packages[appID] = pkg
}

// Remove deletes a package from state.
func (s *State) Remove(appID string) {
	delete(s.Packages, appID)
}

// Get returns a package by app ID, or nil if not installed.
func (s *State) Get(appID string) *Package {
	return s.Packages[appID]
}
