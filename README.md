# zapstore-cli

To install dependencies:

```bash
dart pub get
```

To run:

```bash
dart lib/main.dart
```

To build:

```bash
dart compile exe lib/main.dart -o zapstore
```

## Publishing package usage

Run `zapstore publish myapp` in a folder with a `zapstore.yaml` file like:

```yaml
myapp:
  cli:
    identifier: my app
    name: My App
    summary: the app world army knife
    repository: https://github.com/myself/myapp
    builder: npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6
    artifacts:
      nak-v%v-darwin-arm64:
        platform: darwin-arm64
      nak-v%v-linux-amd64:
        platform: linux-x86_64
```

The artifacts map has regular expressions to package paths in releases.
For convenience, use `%v` as placeholder for a version. It will be replaced by `\d+\.\d+(\.\d+)?`. You can write any regex that matches your files.

Inside the map, use the `platform` key to specify the target platform. Formats are included as `f` tags in file metadata events and valid strings at this time are:

 - `darwin-arm64`
 - `darwin-x86_64`
 - `linux-x86_64`
 - `linux-aarch64`

More will be added soon and will be specified in a NIP. These are based off `uname -sm`, lowercased and dashed.

If your file is compressed (zip and tar.gz supported), uncompressing assumes it will find an executable with the exact name of your package.

If the executable has a different name or path inside the compressed file, or has multiple executables, use the `executables` array. Example:

```yaml
phoenixd:
  cli:
    identifier: phoenixd
    name: phoenixd
    repository: https://github.com/acinq/phoenixd
    artifacts:
      phoenix-%v-macos-arm64.zip:
        platform: darwin-arm64
        executables: [phoenix-%v-macos-arm64/phoenixd, phoenix-%v-macos-arm64/phoenix-cli]
```

Publishing is hard-coded to `relay.zap.store` for now. Your pubkey must be whitelisted by zap.store in order for your events to be accepted. Let us know.