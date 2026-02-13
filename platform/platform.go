// Package platform detects the current OS/architecture and maps them
// to NIP-82 platform identifiers and MIME types.
package platform

import "runtime"

// archMap translates Go's GOARCH values to NIP-82 architecture identifiers.
var archMap = map[string]string{
	"arm64": "arm64",
	"amd64": "x86_64",
}

// goArchToNIP82 maps Go arch names to the secondary NIP-82 name used in some contexts.
var goArchToNIP82Arch = map[string]string{
	"arm64": "aarch64",
	"amd64": "x86_64",
}

// platformMIME maps NIP-82 platform identifiers to expected MIME types.
var platformMIME = map[string][]string{
	"darwin-arm64":   {"application/x-mach-binary; arch=arm64"},
	"darwin-x86_64":  {"application/x-mach-binary; arch=x86-64"},
	"linux-aarch64":  {"application/x-executable; format=elf; arch=arm"},
	"linux-x86_64":   {"application/x-executable; format=elf; arch=x86-64"},
	"windows-x86_64": {"application/x-msdownload"},
}

// Info holds the detected platform information.
type Info struct {
	OS   string // runtime.GOOS (e.g. "darwin", "linux", "windows")
	Arch string // runtime.GOARCH (e.g. "arm64", "amd64")

	// NIP-82 identifier used in `f` tags (e.g. "darwin-arm64")
	Platform string

	// MIME types compatible with this platform
	MIMETypes []string
}

// Detect returns platform information for the current OS and architecture.
func Detect() Info {
	return detect(runtime.GOOS, runtime.GOARCH)
}

func detect(goos, goarch string) Info {
	arch := archMap[goarch]
	if arch == "" {
		arch = goarch
	}

	platform := goos + "-" + arch

	// For Linux, use aarch64 in the platform identifier.
	if goos == "linux" {
		if nip82Arch, ok := goArchToNIP82Arch[goarch]; ok {
			platform = goos + "-" + nip82Arch
		}
	}

	mimes := platformMIME[platform]
	if mimes == nil {
		mimes = []string{}
	}

	return Info{
		OS:        goos,
		Arch:      goarch,
		Platform:  platform,
		MIMETypes: mimes,
	}
}

// MatchesMIME reports whether the given MIME type is compatible with this platform.
func (p Info) MatchesMIME(mime string) bool {
	for _, m := range p.MIMETypes {
		if m == mime {
			return true
		}
	}
	return false
}

// MatchesPlatform reports whether the given f-tag value matches this platform.
func (p Info) MatchesPlatform(ftag string) bool {
	return ftag == p.Platform
}
