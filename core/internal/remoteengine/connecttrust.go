package remoteengine

import (
	"crypto/ecdh"
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/sha256"
	"errors"
)

const FeatureConnectTrust = "connect-trust/1"
const IdentityProofVersion = "aer-connect-identity/1"

// A password envelope alone proves knowledge of the password, not ownership
// of an installation key. This separate, domain-separated MAC binds that key
// to this attempt, both device numbers and the entire password envelope.
func identityMAC(shared, viewerPub, hostPub []byte, a ConnectAuth) (string, error) {
	salt := sha256.Sum256([]byte(a.AttemptID))
	info := append([]byte(IdentityProofVersion+"\x00"), viewerPub...)
	info = append(info, hostPub...)
	key, err := hkdf.Key(sha256.New, shared, salt[:], string(info), 32)
	if err != nil {
		return "", err
	}
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(IdentityProofVersion + "\x00" + a.AttemptID + "\x00" + a.ViewerNumber + "\x00" + a.TargetNumber + "\x00" + a.EphPub + "\x00" + a.Ciphertext))
	return EncodeKey(mac.Sum(nil)), nil
}

func ProveIdentity(viewer *ecdh.PrivateKey, hostPub string, a ConnectAuth) (ConnectAuth, error) {
	hp, err := DecodeKey(hostPub)
	if err != nil {
		return a, err
	}
	pub, err := ecdh.X25519().NewPublicKey(hp)
	if err != nil {
		return a, err
	}
	shared, err := viewer.ECDH(pub)
	if err != nil {
		return a, err
	}
	a.ViewerBoxPub = EncodeKey(viewer.PublicKey().Bytes())
	a.IdentityProof, err = identityMAC(shared, viewer.PublicKey().Bytes(), hp, a)
	return a, err
}

func VerifyIdentity(host *ecdh.PrivateKey, a ConnectAuth) error {
	vp, err := DecodeKey(a.ViewerBoxPub)
	if err != nil || a.ViewerNumber == "" {
		return errors.New("invalid installation proof")
	}
	pub, err := ecdh.X25519().NewPublicKey(vp)
	if err != nil {
		return err
	}
	shared, err := host.ECDH(pub)
	if err != nil {
		return err
	}
	expected, err := identityMAC(shared, vp, host.PublicKey().Bytes(), a)
	actual, decodeErr := DecodeKey(a.IdentityProof)
	want, _ := DecodeKey(expected)
	if err != nil || decodeErr != nil || !hmac.Equal(actual, want) {
		return errors.New("invalid installation proof")
	}
	return nil
}
