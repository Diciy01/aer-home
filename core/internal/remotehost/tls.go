package remotehost

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"os"
	"path/filepath"
	"time"
)

// EnsureCert returns the paths of the RDP certificate and key, creating a
// self-signed RSA pair in stateDir when none is configured. Clients do not
// trust it blindly: they pin it through Core.
func EnsureCert(c *Config) (certPEM string, err error) {
	return ensureCertUntil(c, time.Time{})
}

func ensureCertUntil(c *Config, expires time.Time) (certPEM string, err error) {
	if c.TLSCert == "" {
		c.TLSCert, c.TLSKey = filepath.Join(c.StateDir, "rdp-tls.crt"), filepath.Join(c.StateDir, "rdp-tls.key")
		if _, err := os.Stat(c.TLSCert); os.IsNotExist(err) {
			if err := os.MkdirAll(c.StateDir, 0o700); err != nil {
				return "", err
			}
			key, err := rsa.GenerateKey(rand.Reader, 2048)
			if err != nil {
				return "", err
			}
			host, _ := os.Hostname()
			tpl := &x509.Certificate{SerialNumber: big.NewInt(time.Now().UnixNano()), Subject: pkix.Name{CommonName: "AER Remote " + host},
				NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().AddDate(2, 0, 0),
				KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
			if !expires.IsZero() {
				tpl.NotAfter = expires
			}
			der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &key.PublicKey, key)
			if err != nil {
				return "", err
			}
			if err := os.WriteFile(c.TLSKey, pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)}), 0o600); err != nil {
				return "", err
			}
			if err := os.WriteFile(c.TLSCert, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644); err != nil {
				return "", err
			}
		}
	}
	raw, err := os.ReadFile(c.TLSCert)
	return string(raw), err
}
