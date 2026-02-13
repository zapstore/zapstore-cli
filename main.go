package main

import (
	"fmt"
	"os"

	"github.com/zapstore/zapstore/cmd"
	"github.com/zapstore/zapstore/store"
	"github.com/zapstore/zapstore/ui"
)

const usage = `zapstore - a Nostr-based package manager

Usage:
  zapstore <command> [arguments]

Commands:
  install <app-id>     Install a package
  update  [<app-id>]   Update one or all installed packages
  remove  <app-id>     Remove an installed package
  list                 List installed packages
  search  <query>      Search for packages on the relay
  cleanup              Remove old versions and dangling symlinks
`

func main() {
	if len(os.Args) < 2 {
		fmt.Print(usage)
		os.Exit(1)
	}

	// Migrate from legacy ~/.zapstore if needed
	if err := store.MigrateIfNeeded(); err != nil {
		fmt.Fprintf(os.Stderr, "%s migration: %v\n", ui.Cross(), err)
		// Non-fatal: continue even if migration fails
	}

	var err error

	switch os.Args[1] {
	case "install":
		if len(os.Args) < 3 {
			fatal("usage: zapstore install <app-id>")
		}
		err = cmd.Install(os.Args[2])

	case "update":
		appID := ""
		if len(os.Args) >= 3 {
			appID = os.Args[2]
		}
		err = cmd.Update(appID)

	case "remove":
		if len(os.Args) < 3 {
			fatal("usage: zapstore remove <app-id>")
		}
		err = cmd.Remove(os.Args[2])

	case "list":
		err = cmd.List()

	case "search":
		if len(os.Args) < 3 {
			fatal("usage: zapstore search <query>")
		}
		err = cmd.Search(os.Args[2])

	case "cleanup":
		err = cmd.Cleanup()

	case "help", "--help", "-h":
		fmt.Print(usage)
		return

	default:
		fmt.Fprintf(os.Stderr, "%s unknown command: %s\n\n", ui.Cross(), os.Args[1])
		fmt.Print(usage)
		os.Exit(1)
	}

	if err != nil {
		fmt.Fprintf(os.Stderr, "\n%s %v\n", ui.Cross(), err)
		os.Exit(1)
	}
}

func fatal(msg string) {
	fmt.Fprintln(os.Stderr, msg)
	os.Exit(1)
}
