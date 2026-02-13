package cmd

import (
	"fmt"

	"github.com/zapstore/zapstore/install"
	"github.com/zapstore/zapstore/store"
	"github.com/zapstore/zapstore/ui"
)

// Remove uninstalls a package.
func Remove(appID string) error {
	state, err := store.Load()
	if err != nil {
		return fmt.Errorf("loading state: %w", err)
	}

	pkg := state.Get(appID)
	if pkg == nil {
		return fmt.Errorf("package %q is not installed", appID)
	}

	sp := ui.NewSpinner(fmt.Sprintf("Removing %s v%s...", appID, pkg.Version))
	sp.Start()

	if err := install.Uninstall(appID, pkg.Executables); err != nil {
		sp.StopWithError(fmt.Sprintf("Failed to remove %s", appID))
		return fmt.Errorf("uninstalling: %w", err)
	}

	state.Remove(appID)
	if err := state.Save(); err != nil {
		sp.StopWithError("Failed to save state")
		return fmt.Errorf("saving state: %w", err)
	}

	sp.StopWithSuccess(fmt.Sprintf("Removed %s %s", appID, ui.Dim("v"+pkg.Version)))
	return nil
}
