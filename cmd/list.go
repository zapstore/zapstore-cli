package cmd

import (
	"fmt"
	"sort"
	"strings"

	"github.com/zapstore/zapstore/store"
	"github.com/zapstore/zapstore/ui"
)

// List prints all installed packages.
func List() error {
	state, err := store.Load()
	if err != nil {
		return fmt.Errorf("loading state: %w", err)
	}

	if len(state.Packages) == 0 {
		ui.Infof("No packages installed.")
		return nil
	}

	// Sort by app ID
	ids := make([]string, 0, len(state.Packages))
	for id := range state.Packages {
		ids = append(ids, id)
	}
	sort.Strings(ids)

	// Calculate column widths
	maxID, maxVer, maxExe := len("PACKAGE"), len("VERSION"), len("EXECUTABLES")
	for _, id := range ids {
		pkg := state.Packages[id]
		if len(id) > maxID {
			maxID = len(id)
		}
		if len(pkg.Version) > maxVer {
			maxVer = len(pkg.Version)
		}
		exe := strings.Join(pkg.Executables, ", ")
		if len(exe) > maxExe {
			maxExe = len(exe)
		}
	}

	fmt.Println()
	ui.TableHeader(
		[]int{maxID, maxVer, maxExe, 19},
		"PACKAGE", "VERSION", "EXECUTABLES", "INSTALLED",
	)

	for _, id := range ids {
		pkg := state.Packages[id]
		exe := strings.Join(pkg.Executables, ", ")
		installed := pkg.InstalledAt
		if len(installed) > 19 {
			installed = installed[:19]
		}
		fmt.Printf("%-*s  %-*s  %-*s  %s\n",
			maxID, id,
			maxVer, ui.Bold(pkg.Version),
			maxExe, exe,
			ui.Dim(installed),
		)
	}

	fmt.Printf("\n%s\n", ui.Dim(fmt.Sprintf("%d package(s) installed.", len(ids))))
	return nil
}
