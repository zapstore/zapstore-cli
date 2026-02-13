# zapstore

A standalone CLI package manager for [zapstore](https://zapstore.dev), built on Nostr.

## Install

```bash
go install github.com/zapstore/zapstore@latest
```

Or download a pre-built binary from the [releases page](https://github.com/zapstore/zapstore/releases).

## Usage

```
zapstore install <app-id>      # fetch from relay, download, verify, install
zapstore update [<app-id>]     # update one or all installed packages
zapstore remove <app-id>       # uninstall
zapstore list                  # show installed packages
zapstore search <query>        # discover packages on relay
zapstore cleanup               # remove old versions and dangling symlinks
```

### Examples

```bash
# Search for packages
zapstore search jq

# Install a package
zapstore install com.github.jqlang.jq

# List installed packages
zapstore list

# Update all packages
zapstore update

# Remove a package
zapstore remove com.github.jqlang.jq

# Clean up old versions
zapstore cleanup
```

## How it works

1. Queries the zapstore relay (`wss://relay.zapstore.dev`) for app, release, and asset metadata (Nostr kinds 32267, 30063, 3063)
2. Filters assets by your current platform and architecture
3. Downloads the binary and verifies its SHA-256 hash against the signed event
4. Places the binary in `<data-dir>/packages/<app-id>/<version>/` and symlinks it into `<data-dir>/bin/`

### Filesystem layout

zapstore follows the [XDG Base Directory Specification](https://specifications.freedesktop.org/basedir-spec/latest/):

| Path | Purpose | Default |
|------|---------|---------|
| `$XDG_DATA_HOME/zapstore/packages/` | Installed binaries | `~/.local/share/zapstore/packages/` |
| `$XDG_DATA_HOME/zapstore/bin/` | Symlinks to active versions | `~/.local/share/zapstore/bin/` |
| `$XDG_STATE_HOME/zapstore/state.json` | Installed package metadata | `~/.local/state/zapstore/state.json` |

Add the bin directory to your `PATH`:

```bash
export PATH="$HOME/.local/share/zapstore/bin:$PATH"
```

**Migration:** If you have an existing `~/.zapstore` directory, it will be automatically migrated to the XDG paths on first run.

## Building from source

```bash
git clone https://github.com/zapstore/zapstore.git
cd zapstore
go build -o zapstore .
```

## Environment variables

| Variable | Description |
|----------|-------------|
| `XDG_DATA_HOME` | Override data directory (default: `~/.local/share`) |
| `XDG_STATE_HOME` | Override state directory (default: `~/.local/state`) |
| `NO_COLOR` | Disable colored terminal output |

## License

MIT
