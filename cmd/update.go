package cmd

import (
	"context"
	"fmt"
	"sort"
	"time"

	"github.com/zapstore/zapstore/install"
	"github.com/zapstore/zapstore/nostr"
	"github.com/zapstore/zapstore/platform"
	"github.com/zapstore/zapstore/store"
	"github.com/zapstore/zapstore/ui"
	"github.com/zapstore/zapstore/version"
)

// Update checks for and applies updates. If appID is empty, updates all
// installed packages.
func Update(appID string) error {
	state, err := store.Load()
	if err != nil {
		return fmt.Errorf("loading state: %w", err)
	}

	if len(state.Packages) == 0 {
		ui.Infof("No packages installed.")
		return nil
	}

	// Determine which packages to update
	var targets []string
	if appID != "" {
		if state.Get(appID) == nil {
			return fmt.Errorf("package %q is not installed", appID)
		}
		targets = []string{appID}
	} else {
		for id := range state.Packages {
			targets = append(targets, id)
		}
		sort.Strings(targets)
	}

	plat := platform.Detect()
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()

	updated := 0
	for _, id := range targets {
		pkg := state.Get(id)

		sp := ui.NewSpinner(fmt.Sprintf("Checking %s %s...", id, ui.Dim("v"+pkg.Version)))
		sp.Start()

		app, release, asset, err := nostr.Resolve(ctx, nostr.RelayURL(), id, plat)
		if err != nil {
			sp.StopWithError(fmt.Sprintf("%s: %v", id, err))
			continue
		}

		if !version.CanUpgrade(pkg.Version, release.Version) {
			sp.StopWithSuccess(fmt.Sprintf("%s %s", id, ui.Dim("up to date")))
			continue
		}

		sp.StopWithSuccess(fmt.Sprintf("%s %s %s %s", id, ui.Dim("v"+pkg.Version), ui.Arrow(), ui.Bold("v"+release.Version)))

		result, err := install.Run(install.Options{
			AppID:    id,
			Version:  release.Version,
			URL:      asset.URL,
			Hash:     asset.Hash,
			Filename: asset.Filename,
			Pubkey:   app.Pubkey,
			EventID:  asset.Event.ID,
		})
		if err != nil {
			ui.Errorf("%s: %v", id, err)
			continue
		}

		state.Add(id, &store.Package{
			Pubkey:       app.Pubkey,
			Version:      release.Version,
			Executables:  []string{result.BinaryName},
			AssetEventID: asset.Event.ID,
		})

		updated++
	}

	if err := state.Save(); err != nil {
		return fmt.Errorf("saving state: %w", err)
	}

	fmt.Println()
	if updated == 0 {
		ui.Successf("All packages are up to date.")
	} else {
		ui.Successf("Updated %d package(s).", updated)
	}

	return nil
}
