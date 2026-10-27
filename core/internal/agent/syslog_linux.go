//go:build linux

package agent

import "time"

func newSystemLogSource(every time.Duration) Source { return NewJournalSource(every) }
