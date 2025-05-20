# zapstore-cli

The permissionless package manager.

## Download binaries

https://github.com/zapstore/zapstore-cli/releases/

## From source

Download and select release:

```bash
git clone https://github.com/zapstore/zapstore-cli.git
cd zapstore-cli
git checkout <tag> # select a release from here: https://github.com/zapstore/zapstore-cli/tags
```

Please do not run it from `master` or any other feature branch.

Install dependencies:

```bash
dart pub get
```

Build and run:

```bash
dart compile exe lib/main.dart -o zapstore
./zapstore
```

## Managing packages

```bash
zapstore install <package>
zapstore remove <package>
zapstore list
```

Run `zapstore --help` for more information.

## Publishing a package

Run `zapstore publish myapp` in a folder with a `zapstore.yaml` file and a snippet describing your app.

There are two publishing modes: Github and local.

For Github, assets should be listed in the `assets` list. These are regular expressions that describe package names, as they appear in Github releases.
For convenience, use `%v` as placeholder for a version. It will be replaced by `\d+\.\d+(?:\.\d+)?`, but you can write any regex that matches your files.

Metadata such as name, description, license, release notes, etc will be pulled from Github as well.

### Android package

Example pulling release from Github:

```yaml
repository: https://github.com/getAlby/go
assets:
  - alby-go-v%v-android.apk
```

In the terminal, run `publish` and optionally specify the name of the app:

```bash
zapstore publish go 
```

If you previously published your package, app (kind 32267) will not be published again by default, unless passing `--overwrite-app`. Similarly if the release (kinds 30063, 1063) exists the program will exit, unless passing `--overwrite-release`.

```yaml
name: Alby Go
description: A simple lightning mobile wallet interface that works great with Alby Hub.
repository: https://github.com/getAlby/go
license: MIT
assets:
  - localfile.apk
```

```bash
zapstore publish go -a ~/path/to/alby-go-v1.4.1-android.apk -v 1.4.1
```

If you have multiple assets, run this command once with multiple `-a` arguments and a version (`-v`). They all will be uploaded to `cdn.zapstore.dev`.

If you want to add release notes, provide the release notes Markdown file to `-n`. For icon and images, see `--icon` and `--image`.

You will be prompted for your nsec, but you can also pass it via the `NSEC` environment variable. This is the only available option for signing at the moment. NIP-46 and NIP-07 signing are planned.

For more run `zapstore help publish`.

Note that `apktool` is required to extract APK information. If you don't have it in your path, you can install it via `zapstore install apktool` or with other package managers (brew, apt, etc).

### CLI package

```yaml
name: My App
summary: the app world army knife
repository: https://github.com/myself/myapp
assets:
  - nak-v%v-darwin-arm64 - not %v
  - nak-v%v-linux-amd64
```

Inside the map, use the `platforms` key to specify the target platform. Formats are included as `f` tags in file metadata events and valid strings at this time are:

 - `darwin-arm64`
 - `darwin-x86_64`
 - `linux-x86_64`
 - `linux-aarch64`

More will be added soon and will be specified in a NIP. These are based off `uname -sm`, lowercased and dashed.

If your file is compressed (zip and tar.gz supported), uncompressing assumes it will find an executable with the exact identifier of your package.

Use the `executables` array only if the executable has a different name or path inside the compressed file, and/or it has multiple executables. Example:

```yaml
name: phoenixd
repository: https://github.com/acinq/phoenixd
assets:
  - phoenix-%v-macos-arm64.zip
executables: [$1/phoenixd, $1/phoenix-cli] # ???
```

You can replace captured groups in `executables`.

Publishing is hard-coded to `relay.zapstore.dev` for now. Your pubkey must be whitelisted by zapstore in order for your events to be accepted. Get in touch!