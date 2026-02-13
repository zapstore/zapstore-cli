// Package ui provides terminal UI components with colored output.
package ui

import (
	"os"

	"github.com/charmbracelet/lipgloss"
)

var (
	// NoColor disables colored output when true.
	NoColor = false

	// Styles
	TitleStyle   lipgloss.Style
	SuccessStyle lipgloss.Style
	ErrorStyle   lipgloss.Style
	WarningStyle lipgloss.Style
	InfoStyle    lipgloss.Style
	DimStyle     lipgloss.Style
	BoldStyle    lipgloss.Style
)

func init() {
	if _, ok := os.LookupEnv("NO_COLOR"); ok {
		NoColor = true
	}
	initStyles()
}

func initStyles() {
	if NoColor {
		TitleStyle = lipgloss.NewStyle()
		SuccessStyle = lipgloss.NewStyle()
		ErrorStyle = lipgloss.NewStyle()
		WarningStyle = lipgloss.NewStyle()
		InfoStyle = lipgloss.NewStyle()
		DimStyle = lipgloss.NewStyle()
		BoldStyle = lipgloss.NewStyle().Bold(true)
		return
	}

	TitleStyle = lipgloss.NewStyle().
		Bold(true).
		Foreground(lipgloss.Color("#e0e0e0"))

	SuccessStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("#6b8c6b")) // Muted sage green

	ErrorStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("#c87070")) // Muted coral red

	WarningStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("#c9a866")) // Muted gold

	InfoStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("#a0a0a0")) // Medium grey

	DimStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("#606060")) // Dark grey

	BoldStyle = lipgloss.NewStyle().
		Bold(true)
}

// Title formats text as a title.
func Title(s string) string { return TitleStyle.Render(s) }

// Success formats text as success message.
func Success(s string) string { return SuccessStyle.Render(s) }

// Error formats text as error message.
func Error(s string) string { return ErrorStyle.Render(s) }

// Warning formats text as warning message.
func Warning(s string) string { return WarningStyle.Render(s) }

// Info formats text as info message.
func Info(s string) string { return InfoStyle.Render(s) }

// Dim formats text as dimmed.
func Dim(s string) string { return DimStyle.Render(s) }

// Bold formats text as bold.
func Bold(s string) string { return BoldStyle.Render(s) }

// Icons used in output.
const (
	IconSuccess = "✓"
	IconError   = "✗"
	IconWarning = "⚠"
	IconArrow   = "→"
	IconDot     = "·"
	IconPkg     = "◆"
)

// FallbackIcon returns an ASCII fallback when NoColor is set.
func FallbackIcon(icon, fallback string) string {
	if NoColor {
		return fallback
	}
	return icon
}

// Checkmark returns a styled success checkmark.
func Checkmark() string {
	if NoColor {
		return "[OK]"
	}
	return Success(IconSuccess)
}

// Cross returns a styled error cross.
func Cross() string {
	if NoColor {
		return "[ERROR]"
	}
	return Error(IconError)
}

// Warn returns a styled warning icon.
func Warn() string {
	if NoColor {
		return "[WARN]"
	}
	return Warning(IconWarning)
}

// Arrow returns a styled arrow.
func Arrow() string {
	if NoColor {
		return "->"
	}
	return Info(IconArrow)
}
