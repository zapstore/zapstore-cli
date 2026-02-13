// Package install handles downloading, verifying, placing, and symlinking binaries.
package install

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"github.com/zapstore/zapstore/store"
	"github.com/zapstore/zapstore/ui"
)

// Options configures an install operation.
type Options struct {
	AppID    string
	Version  string
	URL      string
	Hash     string // expected SHA-256 hex
	Filename string // from asset's filename tag
	Pubkey   string
	EventID  string
}

// Result holds information about a completed install.
type Result struct {
	BinaryPath  string
	SymlinkPath string
	BinaryName  string
}

// Run downloads, verifies, and installs a binary.
//
// Filesystem layout:
//
//	<datadir>/packages/<app-id>/<version>/<binary>   ← the actual file
//	<datadir>/bin/<binary>                           ← symlink
func Run(opts Options) (*Result, error) {
	baseDir, err := store.DataDir()
	if err != nil {
		return nil, err
	}

	// Determine the binary name: prefer explicit filename, fall back to URL, then app ID
	binaryName := opts.Filename
	if binaryName == "" {
		binaryName = binaryNameFromURL(opts.URL)
	}
	if binaryName == "" {
		binaryName = opts.AppID
	}

	// Create version directory
	pkgDir := filepath.Join(baseDir, "packages", opts.AppID, opts.Version)
	if err := os.MkdirAll(pkgDir, 0o755); err != nil {
		return nil, fmt.Errorf("creating install directory: %w", err)
	}

	binaryPath := filepath.Join(pkgDir, binaryName)

	// Download
	sp := ui.NewSpinner(fmt.Sprintf("Downloading %s...", binaryName))
	sp.Start()
	data, err := download(opts.URL)
	if err != nil {
		sp.StopWithError(fmt.Sprintf("Download failed: %s", binaryName))
		return nil, fmt.Errorf("downloading: %w", err)
	}
	sp.StopWithSuccess(fmt.Sprintf("Downloaded %s (%s)", binaryName, formatBytes(int64(len(data)))))

	// Verify hash
	if opts.Hash != "" {
		if err := verifyHash(data, opts.Hash); err != nil {
			// Clean up on hash mismatch
			os.RemoveAll(pkgDir)
			return nil, err
		}
		ui.Infof("Hash verified %s", ui.Dim("(SHA-256)"))
	}

	// Write binary
	if err := os.WriteFile(binaryPath, data, 0o755); err != nil {
		return nil, fmt.Errorf("writing binary: %w", err)
	}

	// Create symlink
	binDir := filepath.Join(baseDir, "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		return nil, fmt.Errorf("creating bin directory: %w", err)
	}

	symlinkPath := filepath.Join(binDir, binaryName)
	os.Remove(symlinkPath)

	relTarget := filepath.Join("..", "packages", opts.AppID, opts.Version, binaryName)
	if err := os.Symlink(relTarget, symlinkPath); err != nil {
		return nil, fmt.Errorf("creating symlink: %w", err)
	}

	// Clean up old versions of this app (keep only the one just installed)
	cleanupOldVersions(baseDir, opts.AppID, opts.Version)

	return &Result{
		BinaryPath:  binaryPath,
		SymlinkPath: symlinkPath,
		BinaryName:  binaryName,
	}, nil
}

// Uninstall removes the app directory, symlinks, and state entry.
func Uninstall(appID string, executables []string) error {
	baseDir, err := store.DataDir()
	if err != nil {
		return err
	}

	// Remove the entire app package directory (all versions)
	appDir := filepath.Join(baseDir, "packages", appID)
	if err := os.RemoveAll(appDir); err != nil {
		return fmt.Errorf("removing app directory: %w", err)
	}

	// Remove symlinks from bin/
	binDir := filepath.Join(baseDir, "bin")
	for _, exe := range executables {
		symlinkPath := filepath.Join(binDir, exe)
		target, err := os.Readlink(symlinkPath)
		if err != nil {
			continue
		}
		if strings.Contains(target, appID+"/") {
			os.Remove(symlinkPath)
		}
	}

	return nil
}

// Cleanup removes old version directories that are not referenced by any
// symlink or state entry. Returns the number of directories removed and
// total bytes freed.
func Cleanup() (removed int, bytesFreed int64, err error) {
	baseDir, err := store.DataDir()
	if err != nil {
		return 0, 0, err
	}

	state, err := store.Load()
	if err != nil {
		return 0, 0, err
	}

	pkgRoot := filepath.Join(baseDir, "packages")
	apps, err := os.ReadDir(pkgRoot)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, 0, nil
		}
		return 0, 0, err
	}

	for _, appEntry := range apps {
		if !appEntry.IsDir() {
			continue
		}
		appID := appEntry.Name()
		appDir := filepath.Join(pkgRoot, appID)

		versions, err := os.ReadDir(appDir)
		if err != nil {
			continue
		}

		// Determine the active version from state
		activeVersion := ""
		if pkg := state.Get(appID); pkg != nil {
			activeVersion = pkg.Version
		}

		for _, verEntry := range versions {
			if !verEntry.IsDir() {
				continue
			}
			ver := verEntry.Name()
			if ver == activeVersion {
				continue
			}

			// This version is not active — remove it
			versionDir := filepath.Join(appDir, ver)
			size := dirSize(versionDir)
			if err := os.RemoveAll(versionDir); err == nil {
				removed++
				bytesFreed += size
			}
		}

		// If the app has no state entry at all (orphaned), and the
		// directory is now empty, remove the app directory too.
		if activeVersion == "" {
			remaining, _ := os.ReadDir(appDir)
			if len(remaining) == 0 {
				os.Remove(appDir)
			}
		}
	}

	// Clean up dangling symlinks in bin/
	binDir := filepath.Join(baseDir, "bin")
	links, err := os.ReadDir(binDir)
	if err == nil {
		for _, link := range links {
			linkPath := filepath.Join(binDir, link.Name())
			target, err := os.Readlink(linkPath)
			if err != nil {
				continue
			}
			// Resolve relative to binDir
			abs := filepath.Join(binDir, target)
			if _, err := os.Stat(abs); os.IsNotExist(err) {
				os.Remove(linkPath)
			}
		}
	}

	return removed, bytesFreed, nil
}

// --------------------------------------------------------------------------
// Helpers
// --------------------------------------------------------------------------

// cleanupOldVersions removes version directories for an app other than the
// specified current version.
func cleanupOldVersions(baseDir, appID, currentVersion string) {
	appDir := filepath.Join(baseDir, "packages", appID)
	entries, err := os.ReadDir(appDir)
	if err != nil {
		return
	}
	for _, entry := range entries {
		if entry.IsDir() && entry.Name() != currentVersion {
			os.RemoveAll(filepath.Join(appDir, entry.Name()))
		}
	}
}

func download(url string) ([]byte, error) {
	resp, err := http.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d: %s", resp.StatusCode, resp.Status)
	}

	return io.ReadAll(resp.Body)
}

func verifyHash(data []byte, expectedHex string) error {
	h := sha256.Sum256(data)
	got := hex.EncodeToString(h[:])
	if got != expectedHex {
		return fmt.Errorf("hash mismatch: expected %s, got %s", expectedHex, got)
	}
	return nil
}

func binaryNameFromURL(url string) string {
	parts := strings.Split(url, "/")
	if len(parts) == 0 {
		return ""
	}
	name := parts[len(parts)-1]
	if i := strings.Index(name, "?"); i != -1 {
		name = name[:i]
	}
	return name
}

// dirSize returns the total size of files in a directory tree.
func dirSize(path string) int64 {
	var size int64
	filepath.Walk(path, func(_ string, info os.FileInfo, err error) error {
		if err == nil && !info.IsDir() {
			size += info.Size()
		}
		return nil
	})
	return size
}

// formatBytes formats bytes into human-readable form.
func formatBytes(b int64) string {
	const unit = 1024
	if b < unit {
		return fmt.Sprintf("%d B", b)
	}
	div, exp := int64(unit), 0
	for n := b / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(b)/float64(div), "KMGTPE"[exp])
}
