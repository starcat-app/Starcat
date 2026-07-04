package handler

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"testing"
)

func TestValidCreemSignature(t *testing.T) {
	body := []byte(`{"eventType":"checkout.completed"}`)
	secret := "whsec_test"
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write(body)
	signature := hex.EncodeToString(mac.Sum(nil))

	if !validCreemSignature(body, secret, signature) {
		t.Fatal("expected signature to be valid")
	}
	if validCreemSignature(body, secret, "bad") {
		t.Fatal("expected bad signature to be invalid")
	}
}
