package remotehost

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"io"
	"math/big"
)

func bytesReader(b []byte) io.Reader { return bytes.NewReader(b) }

const alnum = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

// newPassword: 30 random alphanumerics (≈178 bits). The length matters:
// Remmina treats a password that decodes as base64 to a multiple of 8
// bytes as its own encrypted secret and mangles it (verified: 32 and 64
// characters fail, 24/30/36/44 pass); 30 base64 characters decode to 22.
func newPassword() string {
	out := make([]byte, 30)
	max := big.NewInt(int64(len(alnum)))
	for i := range out {
		n, _ := rand.Int(rand.Reader, max)
		out[i] = alnum[n.Int64()]
	}
	return string(out)
}

func newToken() string {
	b := make([]byte, 32)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
