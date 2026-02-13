package ui

import (
	"fmt"
	"io"
	"os"
	"sync"
	"time"
)

// DefaultFrames are the default spinner animation frames.
var DefaultFrames = []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}

// SimpleFrames are ASCII fallback frames.
var SimpleFrames = []string{"|", "/", "-", "\\"}

// Spinner displays a spinning animation during long operations.
type Spinner struct {
	message string
	frames  []string
	index   int
	done    chan struct{}
	wg      sync.WaitGroup
	writer  io.Writer
	active  bool
	mu      sync.Mutex
}

// NewSpinner creates a new spinner with a message.
func NewSpinner(message string) *Spinner {
	frames := DefaultFrames
	if NoColor {
		frames = SimpleFrames
	}
	return &Spinner{
		message: message,
		frames:  frames,
		writer:  os.Stderr,
		done:    make(chan struct{}),
	}
}

// Start begins the spinner animation.
func (s *Spinner) Start() {
	s.mu.Lock()
	if s.active {
		s.mu.Unlock()
		return
	}
	s.active = true
	s.done = make(chan struct{})
	s.mu.Unlock()

	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		ticker := time.NewTicker(80 * time.Millisecond)
		defer ticker.Stop()

		for {
			select {
			case <-s.done:
				return
			case <-ticker.C:
				s.mu.Lock()
				frame := s.frames[s.index]
				s.index = (s.index + 1) % len(s.frames)
				msg := s.message
				s.mu.Unlock()

				fmt.Fprintf(s.writer, "\r\033[K%s %s", InfoStyle.Render(frame), msg)
			}
		}
	}()
}

// Stop stops the spinner and clears the line.
func (s *Spinner) Stop() {
	s.mu.Lock()
	if !s.active {
		s.mu.Unlock()
		return
	}
	s.active = false
	close(s.done)
	s.mu.Unlock()

	s.wg.Wait()
	fmt.Fprintf(s.writer, "\r\033[K")
}

// StopWithSuccess stops the spinner with a success message.
func (s *Spinner) StopWithSuccess(message string) {
	s.Stop()
	fmt.Fprintf(s.writer, "%s %s\n", Checkmark(), message)
}

// StopWithError stops the spinner with an error message.
func (s *Spinner) StopWithError(message string) {
	s.Stop()
	fmt.Fprintf(s.writer, "%s %s\n", Cross(), message)
}

// StopWithWarning stops the spinner with a warning message.
func (s *Spinner) StopWithWarning(message string) {
	s.Stop()
	fmt.Fprintf(s.writer, "%s %s\n", Warn(), message)
}

// UpdateMessage updates the spinner message while it's running.
func (s *Spinner) UpdateMessage(message string) {
	s.mu.Lock()
	s.message = message
	s.mu.Unlock()
}
