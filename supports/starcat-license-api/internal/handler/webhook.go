package handler

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
)

type CreemWebhookHandler struct {
	secret string
}

func NewCreemWebhookHandler(secret string) *CreemWebhookHandler {
	return &CreemWebhookHandler{secret: secret}
}

func (h *CreemWebhookHandler) Handle(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		writeError(w, http.StatusBadRequest, "BAD_REQUEST", "failed to read body")
		return
	}
	if h.secret != "" && !validCreemSignature(body, h.secret, r.Header.Get("creem-signature")) {
		writeError(w, http.StatusUnauthorized, "BAD_SIGNATURE", "invalid Creem signature")
		return
	}

	var event struct {
		ID        string `json:"id"`
		EventType string `json:"eventType"`
	}
	_ = json.Unmarshal(body, &event)

	writeJSON(w, map[string]string{
		"status":    "ok",
		"eventID":   event.ID,
		"eventType": event.EventType,
	})
}

func validCreemSignature(body []byte, secret, signature string) bool {
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write(body)
	expected := mac.Sum(nil)
	actual, err := hex.DecodeString(signature)
	if err != nil {
		return false
	}
	return hmac.Equal(actual, expected)
}
