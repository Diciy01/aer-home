package remotehost

import (
	"math/rand/v2"
	"time"
)

// Backoff is exponential with ±25 % jitter, so many hosts that lost the
// Gateway at the same moment do not come back in lockstep.
type Backoff struct {
	min, max, cur time.Duration
}

// NewBackoff starts at min and doubles up to max.
func NewBackoff(min, max time.Duration) *Backoff { return &Backoff{min: min, max: max} }

// Next returns the delay before the next try.
func (b *Backoff) Next() time.Duration {
	if b.cur == 0 {
		b.cur = b.min
	} else {
		b.cur = min(2*b.cur, b.max)
	}
	j := time.Duration(rand.Int64N(int64(b.cur)/2+1)) - b.cur/4
	return max(b.min/2, b.cur+j)
}

// Reset after a success.
func (b *Backoff) Reset() { b.cur = 0 }
