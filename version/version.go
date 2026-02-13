// Package version implements NIP-82 Appendix D version comparison.
//
// Rules (pragmatic superset of Semantic Versioning):
//
//   - Optional v/V prefix is stripped.
//   - Core version is dot-separated numeric parts, compared numerically.
//   - Pre-release suffix (after first '-') is lower than the same version
//     without one (1.0.0-rc < 1.0.0).
//   - Pre-release identifiers are split on '.' and compared component by
//     component: numeric segments compared as integers, non-numeric compared
//     lexicographically, numeric < non-numeric (SemVer §11).
//   - Build metadata (after '+') is ignored.
package version

import (
	"strconv"
	"strings"
)

// Compare returns:
//
//	-1 if a < b
//	 0 if a == b
//	+1 if a > b
func Compare(a, b string) int {
	va := parse(a)
	vb := parse(b)
	return va.cmp(vb)
}

// CanUpgrade reports whether current is newer than installed.
func CanUpgrade(installed, current string) bool {
	return Compare(current, installed) > 0
}

// --------------------------------------------------------------------------
// Internal
// --------------------------------------------------------------------------

type version struct {
	parts      []int
	preRelease []identifier
}

func parse(s string) version {
	// 1. Strip leading v/V
	s = strings.TrimPrefix(s, "v")
	s = strings.TrimPrefix(s, "V")

	// 2. Drop build metadata (+...)
	if i := strings.Index(s, "+"); i != -1 {
		s = s[:i]
	}

	// 3. Split pre-release (-...)
	var core, pre string
	if i := strings.Index(s, "-"); i != -1 {
		core = s[:i]
		pre = s[i+1:]
	} else {
		core = s
	}

	// Parse numeric dot parts
	rawParts := strings.Split(core, ".")
	parts := make([]int, len(rawParts))
	for i, p := range rawParts {
		n, err := strconv.Atoi(p)
		if err != nil {
			n = 0
		}
		parts[i] = n
	}

	// Parse pre-release identifiers
	var preParts []identifier
	if pre != "" {
		for _, id := range strings.Split(pre, ".") {
			preParts = append(preParts, newIdentifier(id))
		}
	}

	return version{parts: parts, preRelease: preParts}
}

func (v version) cmp(other version) int {
	// 1. Compare numeric dot parts
	maxLen := len(v.parts)
	if len(other.parts) > maxLen {
		maxLen = len(other.parts)
	}
	for i := 0; i < maxLen; i++ {
		a := 0
		if i < len(v.parts) {
			a = v.parts[i]
		}
		b := 0
		if i < len(other.parts) {
			b = other.parts[i]
		}
		if a < b {
			return -1
		}
		if a > b {
			return 1
		}
	}

	// 2. Pre-release vs stable
	aHasPre := len(v.preRelease) > 0
	bHasPre := len(other.preRelease) > 0
	if aHasPre && !bHasPre {
		return -1 // pre-release < stable
	}
	if !aHasPre && bHasPre {
		return 1 // stable > pre-release
	}

	// 3. Compare pre-release identifiers
	maxPre := len(v.preRelease)
	if len(other.preRelease) > maxPre {
		maxPre = len(other.preRelease)
	}
	for i := 0; i < maxPre; i++ {
		var aID, bID identifier
		if i < len(v.preRelease) {
			aID = v.preRelease[i]
		} else {
			aID = emptyIdentifier
		}
		if i < len(other.preRelease) {
			bID = other.preRelease[i]
		} else {
			bID = emptyIdentifier
		}
		if c := aID.cmp(bID); c != 0 {
			return c
		}
	}

	return 0
}

// --------------------------------------------------------------------------

type identifier struct {
	value     string
	isNumeric bool
	isEmpty   bool
}

var emptyIdentifier = identifier{isEmpty: true}

func newIdentifier(s string) identifier {
	_, err := strconv.Atoi(s)
	return identifier{value: s, isNumeric: err == nil}
}

func (id identifier) cmp(other identifier) int {
	if id.isEmpty && other.isEmpty {
		return 0
	}
	if id.isEmpty {
		return -1
	}
	if other.isEmpty {
		return 1
	}

	// Both numeric → integer comparison
	if id.isNumeric && other.isNumeric {
		a, _ := strconv.Atoi(id.value)
		b, _ := strconv.Atoi(other.value)
		if a < b {
			return -1
		}
		if a > b {
			return 1
		}
		return 0
	}

	// Mixed: numeric has lower precedence than non-numeric (SemVer §11)
	if id.isNumeric != other.isNumeric {
		if id.isNumeric {
			return -1
		}
		return 1
	}

	// Both non-numeric → lexicographic
	if id.value < other.value {
		return -1
	}
	if id.value > other.value {
		return 1
	}
	return 0
}
