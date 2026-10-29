package remoteengine

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"errors"
)

// RegistrationVersion separates enrollment envelopes from session passwords.
const RegistrationVersion = "aer-connect-registration/1"

// RegistrationBox can be stored/relayed publicly: only this installation's
// private X25519 key can recover the challenge or its issued credentials.
type RegistrationBox struct {
	EphPub     string `json:"ephPub"`
	Nonce      string `json:"nonce"`
	Ciphertext string `json:"ciphertext"`
}

func registrationAEAD(shared []byte, id, instance string, recipient []byte) (cipher.AEAD, error) {
	salt := sha256.Sum256([]byte(RegistrationVersion + "\x00" + id + "\x00" + instance))
	info := append([]byte(RegistrationVersion+"\x00"), recipient...)
	key, err := hkdf.Key(sha256.New, shared, salt[:], string(info), 32)
	if err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

func SealRegistration(pub, id, instance string, plain []byte) (RegistrationBox, error) {
	raw, err := DecodeKey(pub)
	if err != nil {
		return RegistrationBox{}, err
	}
	recipient, err := ecdh.X25519().NewPublicKey(raw)
	if err != nil {
		return RegistrationBox{}, err
	}
	eph, err := NewBoxKey()
	if err != nil {
		return RegistrationBox{}, err
	}
	shared, err := eph.ECDH(recipient)
	if err != nil {
		return RegistrationBox{}, err
	}
	aead, err := registrationAEAD(shared, id, instance, raw)
	if err != nil {
		return RegistrationBox{}, err
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err = rand.Read(nonce); err != nil {
		return RegistrationBox{}, err
	}
	aad := []byte(RegistrationVersion + "\x00" + id + "\x00" + instance)
	return RegistrationBox{EncodeKey(eph.PublicKey().Bytes()), b64.EncodeToString(nonce), b64.EncodeToString(aead.Seal(nil, nonce, plain, aad))}, nil
}

func OpenRegistration(key *ecdh.PrivateKey, id, instance string, box RegistrationBox) ([]byte, error) {
	raw, err := DecodeKey(box.EphPub)
	if err != nil {
		return nil, err
	}
	pub, err := ecdh.X25519().NewPublicKey(raw)
	if err != nil {
		return nil, err
	}
	shared, err := key.ECDH(pub)
	if err != nil {
		return nil, err
	}
	aead, err := registrationAEAD(shared, id, instance, key.PublicKey().Bytes())
	if err != nil {
		return nil, err
	}
	nonce, err := b64.DecodeString(box.Nonce)
	if err != nil || len(nonce) != aead.NonceSize() {
		return nil, errors.New("registration: invalid nonce")
	}
	encrypted, err := b64.DecodeString(box.Ciphertext)
	if err != nil {
		return nil, err
	}
	return aead.Open(nil, nonce, encrypted, []byte(RegistrationVersion+"\x00"+id+"\x00"+instance))
}
