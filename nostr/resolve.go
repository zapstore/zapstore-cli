package nostr

import (
	"context"
	"fmt"
	"strings"

	"github.com/nbd-wtf/go-nostr"
	"github.com/zapstore/zapstore/platform"
	"github.com/zapstore/zapstore/version"
)

// AppInfo holds metadata from a kind 32267 app event.
type AppInfo struct {
	Event   *nostr.Event
	AppID   string // d tag value
	Name    string
	Summary string
	Pubkey  string
}

// ReleaseInfo holds metadata from a kind 30063 release event.
type ReleaseInfo struct {
	Event   *nostr.Event
	Version string
	// AssetEventIDs are the `e` tag references to asset events.
	AssetEventIDs []string
}

// AssetInfo holds metadata from a kind 3063 asset event.
type AssetInfo struct {
	Event    *nostr.Event
	URL      string
	Hash     string // SHA-256 hex
	Platform string // f tag
	MIME     string // m tag
	Filename string // filename tag
}

// ResolveApp queries the relay for a kind 32267 event matching the app ID
// and the current platform. The appID is matched against the `d` tag, and
// the platform's `f` tag value is sent so the relay only returns apps
// available for this OS/arch.
func ResolveApp(ctx context.Context, relayURL, appID string, plat platform.Info) (*AppInfo, error) {
	filters := nostr.Filters{{
		Kinds: []int{KindApp},
		Tags: nostr.TagMap{
			"d": []string{appID},
			"f": []string{plat.Platform},
		},
		Limit: 1,
	}}

	events, err := QueryEvents(ctx, relayURL, filters)
	if err != nil {
		return nil, err
	}
	if len(events) == 0 {
		return nil, fmt.Errorf("app %q not found on relay", appID)
	}

	return appInfoFromEvent(events[0]), nil
}

// ResolveLatestRelease finds the latest release for an app.
//
// It queries for kind 30063 events whose `i` tag matches the app ID,
// then picks the one with the highest version.
func ResolveLatestRelease(ctx context.Context, relayURL string, app *AppInfo) (*ReleaseInfo, error) {
	filters := nostr.Filters{{
		Kinds:   []int{KindRelease},
		Authors: []string{app.Pubkey},
		Tags:    nostr.TagMap{"i": []string{app.AppID}},
	}}

	events, err := QueryEvents(ctx, relayURL, filters)
	if err != nil {
		return nil, err
	}
	if len(events) == 0 {
		return nil, fmt.Errorf("no releases found for %q", app.AppID)
	}

	// Find the latest version.
	// The version is extracted from the `d` tag (format: @<version>) or
	// a `version` tag if present.
	var best *nostr.Event
	var bestVersion string
	for _, ev := range events {
		ver := extractVersion(ev)
		if ver == "" {
			continue
		}
		if best == nil || version.Compare(ver, bestVersion) > 0 {
			best = ev
			bestVersion = ver
		}
	}

	if best == nil {
		return nil, fmt.Errorf("no versioned releases found for %q", app.AppID)
	}

	// Collect asset event IDs from `e` tags
	var assetIDs []string
	for _, tag := range best.Tags {
		if len(tag) >= 2 && tag[0] == "e" {
			assetIDs = append(assetIDs, tag[1])
		}
	}

	return &ReleaseInfo{
		Event:         best,
		Version:       bestVersion,
		AssetEventIDs: assetIDs,
	}, nil
}

// ResolveAssets fetches the asset events referenced by a release and filters
// them for the current platform. Queries both kind 3063 and kind 1063 for
// compatibility with older events.
func ResolveAssets(ctx context.Context, relayURL string, assetEventIDs []string, plat platform.Info) ([]*AssetInfo, error) {
	if len(assetEventIDs) == 0 {
		return nil, fmt.Errorf("release has no asset references")
	}

	// Query by event ID, filtered to our platform's f tag.
	filters := nostr.Filters{{
		IDs:  assetEventIDs,
		Tags: nostr.TagMap{"f": []string{plat.Platform}},
	}}

	events, err := QueryEvents(ctx, relayURL, filters)
	if err != nil {
		return nil, err
	}

	var matched []*AssetInfo
	for _, ev := range events {
		fTag := tagValue(ev, "f")
		mTag := tagValue(ev, "m")

		// Match by platform tag
		if fTag != "" && plat.MatchesPlatform(fTag) {
			matched = append(matched, assetFromEvent(ev))
			continue
		}

		// Fallback: match by MIME type
		if mTag != "" && plat.MatchesMIME(mTag) {
			matched = append(matched, assetFromEvent(ev))
		}
	}

	if len(matched) == 0 {
		return nil, fmt.Errorf("no assets found for platform %s", plat.Platform)
	}

	return matched, nil
}

// SearchApps queries the relay for apps matching a search string,
// filtered to the current platform.
func SearchApps(ctx context.Context, relayURL, query string, plat platform.Info) ([]*AppInfo, error) {
	filters := nostr.Filters{{
		Kinds:  []int{KindApp},
		Tags:   nostr.TagMap{"f": []string{plat.Platform}},
		Search: query,
		Limit:  20,
	}}

	events, err := QueryEvents(ctx, relayURL, filters)
	if err != nil {
		return nil, err
	}

	var results []*AppInfo
	for _, ev := range events {
		results = append(results, appInfoFromEvent(ev))
	}

	return results, nil
}

// Resolve performs the full resolution chain: app → release → asset.
// Returns the app info, release info, and the best matching asset.
func Resolve(ctx context.Context, relayURL, appID string, plat platform.Info) (*AppInfo, *ReleaseInfo, *AssetInfo, error) {
	app, err := ResolveApp(ctx, relayURL, appID, plat)
	if err != nil {
		return nil, nil, nil, err
	}

	release, err := ResolveLatestRelease(ctx, relayURL, app)
	if err != nil {
		return app, nil, nil, err
	}

	assets, err := ResolveAssets(ctx, relayURL, release.AssetEventIDs, plat)
	if err != nil {
		return app, release, nil, err
	}

	// Pick the first matching asset
	return app, release, assets[0], nil
}

// --------------------------------------------------------------------------
// Helpers
// --------------------------------------------------------------------------

func tagValue(ev *nostr.Event, key string) string {
	for _, tag := range ev.Tags {
		if len(tag) >= 2 && tag[0] == key {
			return tag[1]
		}
	}
	return ""
}

// extractVersion gets the version from a release event.
// Checks for a `version` tag first, then parses the `d` tag (format: @<version>).
func extractVersion(ev *nostr.Event) string {
	if v := tagValue(ev, "version"); v != "" {
		return v
	}
	d := tagValue(ev, "d")
	if strings.HasPrefix(d, "@") {
		return d[1:]
	}
	return d
}

func appInfoFromEvent(ev *nostr.Event) *AppInfo {
	appID := tagValue(ev, "d")
	name := tagValue(ev, "name")
	if name == "" {
		name = appID
	}
	return &AppInfo{
		Event:   ev,
		AppID:   appID,
		Name:    name,
		Summary: tagValue(ev, "summary"),
		Pubkey:  ev.PubKey,
	}
}

func assetFromEvent(ev *nostr.Event) *AssetInfo {
	url := tagValue(ev, "url")
	hash := tagValue(ev, "x")

	// Blossom fallback
	if url == "" && hash != "" {
		url = "https://cdn.zapstore.dev/" + hash
	}

	// If url tag is empty, check for any tag with an HTTP value
	if url == "" {
		for _, tag := range ev.Tags {
			if len(tag) >= 2 && strings.HasPrefix(tag[1], "http") {
				url = tag[1]
				break
			}
		}
	}

	return &AssetInfo{
		Event:    ev,
		URL:      url,
		Hash:     hash,
		Platform: tagValue(ev, "f"),
		MIME:     tagValue(ev, "m"),
		Filename: tagValue(ev, "filename"),
	}
}
