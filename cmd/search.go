package cmd

import (
	"context"
	"fmt"
	"time"

	"github.com/zapstore/zapstore/nostr"
	"github.com/zapstore/zapstore/platform"
	"github.com/zapstore/zapstore/ui"
)

// Search queries the relay for apps matching the query and prints results.
func Search(query string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	plat := platform.Detect()

	sp := ui.NewSpinner(fmt.Sprintf("Searching for %q...", query))
	sp.Start()

	apps, err := nostr.SearchApps(ctx, nostr.RelayURL(), query, plat)
	if err != nil {
		sp.StopWithError("Search failed")
		return err
	}

	if len(apps) == 0 {
		sp.StopWithWarning("No results found.")
		return nil
	}

	sp.StopWithSuccess(fmt.Sprintf("Found %d result(s)", len(apps)))
	fmt.Println()

	for _, app := range apps {
		fmt.Printf("  %s %s\n", ui.Bold(app.AppID), "")
		if app.Summary != "" {
			fmt.Printf("    %s\n", ui.Dim(app.Summary))
		}
		fmt.Println()
	}

	return nil
}
