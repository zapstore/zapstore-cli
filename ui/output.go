package ui

import (
	"fmt"
	"strings"
)

// Header prints a section header line.
func Header(title string) {
	if NoColor {
		fmt.Printf("=== %s ===\n", strings.ToUpper(title))
		return
	}
	line := strings.Repeat("─", 50)
	fmt.Println(DimStyle.Render(line))
	fmt.Printf(" %s\n", TitleStyle.Render(title))
	fmt.Println(DimStyle.Render(line))
}

// Statusf prints a status line with an icon and formatted message.
func Statusf(icon, format string, args ...any) {
	msg := fmt.Sprintf(format, args...)
	fmt.Printf("  %s %s\n", icon, msg)
}

// Successf prints a success line.
func Successf(format string, args ...any) {
	Statusf(Checkmark(), format, args...)
}

// Errorf prints an error line.
func Errorf(format string, args ...any) {
	Statusf(Cross(), format, args...)
}

// Warningf prints a warning line.
func Warningf(format string, args ...any) {
	Statusf(Warn(), format, args...)
}

// Infof prints an informational line.
func Infof(format string, args ...any) {
	msg := fmt.Sprintf(format, args...)
	fmt.Printf("  %s %s\n", Info(IconDot), msg)
}

// Resultf prints a final result line (e.g. "Installed foo → ~/.zapstore/bin/foo").
func Resultf(format string, args ...any) {
	msg := fmt.Sprintf(format, args...)
	fmt.Printf("\n  %s %s\n\n", Checkmark(), BoldStyle.Render(msg))
}

// TableHeader prints a formatted table header row.
func TableHeader(widths []int, names ...string) {
	var header, sep strings.Builder
	for i, name := range names {
		w := widths[i]
		if i > 0 {
			header.WriteString("  ")
			sep.WriteString("  ")
		}
		header.WriteString(fmt.Sprintf("%-*s", w, name))
		sep.WriteString(strings.Repeat("─", w))
	}
	if NoColor {
		fmt.Println(header.String())
		fmt.Println(sep.String())
	} else {
		fmt.Println(DimStyle.Render(header.String()))
		fmt.Println(DimStyle.Render(sep.String()))
	}
}
