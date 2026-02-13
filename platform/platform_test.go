package platform

import "testing"

func TestDetect(t *testing.T) {
	tests := []struct {
		goos, goarch string
		wantPlatform string
		wantMIMEs    []string
	}{
		{"darwin", "arm64", "darwin-arm64", []string{"application/x-mach-binary; arch=arm64"}},
		{"darwin", "amd64", "darwin-x86_64", []string{"application/x-mach-binary; arch=x86-64"}},
		{"linux", "arm64", "linux-aarch64", []string{"application/x-executable; format=elf; arch=arm"}},
		{"linux", "amd64", "linux-x86_64", []string{"application/x-executable; format=elf; arch=x86-64"}},
		{"windows", "amd64", "windows-x86_64", []string{"application/x-msdownload"}},
	}

	for _, tt := range tests {
		t.Run(tt.goos+"-"+tt.goarch, func(t *testing.T) {
			info := detect(tt.goos, tt.goarch)
			if info.Platform != tt.wantPlatform {
				t.Errorf("Platform = %q, want %q", info.Platform, tt.wantPlatform)
			}
			if len(info.MIMETypes) != len(tt.wantMIMEs) {
				t.Fatalf("MIMETypes len = %d, want %d", len(info.MIMETypes), len(tt.wantMIMEs))
			}
			for i, m := range info.MIMETypes {
				if m != tt.wantMIMEs[i] {
					t.Errorf("MIMETypes[%d] = %q, want %q", i, m, tt.wantMIMEs[i])
				}
			}
		})
	}
}

func TestMatchesMIME(t *testing.T) {
	info := detect("darwin", "arm64")
	if !info.MatchesMIME("application/x-mach-binary; arch=arm64") {
		t.Error("expected match for darwin arm64 MIME")
	}
	if info.MatchesMIME("application/x-executable; format=elf; arch=arm") {
		t.Error("expected no match for linux arm64 MIME on darwin")
	}
}

func TestMatchesPlatform(t *testing.T) {
	info := detect("linux", "amd64")
	if !info.MatchesPlatform("linux-x86_64") {
		t.Error("expected platform match")
	}
	if info.MatchesPlatform("darwin-arm64") {
		t.Error("expected no platform match")
	}
}
