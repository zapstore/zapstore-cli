package cmd

import (
	"fmt"

	"github.com/zapstore/zapstore/install"
	"github.com/zapstore/zapstore/ui"
)

// Cleanup removes old version directories and dangling symlinks.
func Cleanup() error {
	sp := ui.NewSpinner("Cleaning up...")
	sp.Start()

	removed, bytesFreed, err := install.Cleanup()
	if err != nil {
		sp.StopWithError("Cleanup failed")
		return fmt.Errorf("cleanup: %w", err)
	}

	if removed == 0 {
		sp.StopWithSuccess("Nothing to clean up")
		return nil
	}

	sp.StopWithSuccess(fmt.Sprintf("Removed %d old version(s), freed %s", removed, formatBytes(bytesFreed)))
	return nil
}

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
