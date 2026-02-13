package cmd

import (
	"context"
	"fmt"
	"time"

	"github.com/zapstore/zapstore/install"
	"github.com/zapstore/zapstore/nostr"
	"github.com/zapstore/zapstore/platform"
	"github.com/zapstore/zapstore/store"
	"github.com/zapstore/zapstore/ui"
	"github.com/zapstore/zapstore/version"
)

// Install resolves an app from the relay, downloads, verifies, and installs it.
func Install(appID string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	plat := platform.Detect()
	fmt.Printf("  %s %s\n", ui.Dim("platform"), plat.Platform)

	// Check if already installed
	state, err := store.Load()
	if err != nil {
		return fmt.Errorf("loading state: %w", err)
	}

	// Resolve: app → release → asset
	sp := ui.NewSpinner(fmt.Sprintf("Resolving %s...", appID))
	sp.Start()

	app, release, asset, err := nostr.Resolve(ctx, nostr.RelayURL(), appID, plat)
	if err != nil {
		sp.StopWithError(fmt.Sprintf("Failed to resolve %s", appID))
		return err
	}
	sp.StopWithSuccess(fmt.Sprintf("Found %s %s", ui.Bold(app.Name), ui.Dim("v"+release.Version)))

	// Check if same or newer version already installed
	if pkg := state.Get(appID); pkg != nil {
		if !version.CanUpgrade(pkg.Version, release.Version) {
			ui.Infof("Already up to date %s", ui.Dim("(v"+pkg.Version+")"))
			return nil
		}
		ui.Infof("Upgrading %s %s %s", ui.Dim("v"+pkg.Version), ui.Arrow(), ui.Dim("v"+release.Version))
	}

	// Install
	result, err := install.Run(install.Options{
		AppID:    appID,
		Version:  release.Version,
		URL:      asset.URL,
		Hash:     asset.Hash,
		Filename: asset.Filename,
		Pubkey:   app.Pubkey,
		EventID:  asset.Event.ID,
	})
	if err != nil {
		return err
	}

	// Record in state
	state.Add(appID, &store.Package{
		Pubkey:       app.Pubkey,
		Version:      release.Version,
		Executables:  []string{result.BinaryName},
		AssetEventID: asset.Event.ID,
	})

	if err := state.Save(); err != nil {
		return fmt.Errorf("saving state: %w", err)
	}

	ui.Resultf("Installed %s v%s %s %s", app.Name, release.Version, ui.Arrow(), ui.Dim(result.SymlinkPath))
	return nil
}
