//go:build windows

package agent

import "time"

func newSystemLogSource(every time.Duration) Source { return NewEventLogSource(every) }
