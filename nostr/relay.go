// Package nostr handles connecting to relays and querying events.
package nostr

import (
	"context"
	"fmt"
	"os"

	"github.com/nbd-wtf/go-nostr"
)

const defaultRelay = "wss://relay.zapstore.dev"

// RelayURL returns the relay URL from RELAY_URL env var, or the default.
func RelayURL() string {
	if u := os.Getenv("RELAY_URL"); u != "" {
		return u
	}
	return defaultRelay
}

// Nostr event kinds used by zapstore (NIP-82).
const (
	KindApp     = 32267 // Parameterized replaceable: app metadata
	KindRelease = 30063 // Parameterized replaceable: release
	KindAsset   = 3063  // Asset metadata
)

// QueryEvents connects to the relay, executes the filter, and returns
// all matching events. The connection is closed after the query.
func QueryEvents(ctx context.Context, relayURL string, filters nostr.Filters) ([]*nostr.Event, error) {
	relay, err := nostr.RelayConnect(ctx, relayURL)
	if err != nil {
		return nil, fmt.Errorf("connecting to relay %s: %w", relayURL, err)
	}
	defer relay.Close()

	events, err := relay.QuerySync(ctx, filters[0])
	if err != nil {
		return nil, fmt.Errorf("querying relay: %w", err)
	}

	return events, nil
}
