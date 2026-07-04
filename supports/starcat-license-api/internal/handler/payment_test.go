package handler

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/dong4j/starcat-license-api/internal/model"
	"github.com/dong4j/starcat-license-api/internal/provider"
)

func TestPaymentHandlerCheckoutUsesProvider(t *testing.T) {
	handler := NewPaymentHandler(provider.NewStaticPaymentProvider("creem", "https://pay.starcat.test/checkout", ""))

	request := httptest.NewRequest(http.MethodPost, "/v1/direct/checkout", strings.NewReader(`{"productID":"pro.yearly"}`))
	response := httptest.NewRecorder()

	handler.HandleCheckout(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", response.Code, response.Body.String())
	}

	var body model.PaymentURLResponse
	if err := json.NewDecoder(response.Body).Decode(&body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if body.Provider != "creem" || body.URL != "https://pay.starcat.test/checkout" {
		t.Fatalf("unexpected response: %+v", body)
	}
}

func TestPaymentHandlerReturnsUnavailableWhenProviderMissingURL(t *testing.T) {
	handler := NewPaymentHandler(provider.NewStaticPaymentProvider("creem", "", ""))

	request := httptest.NewRequest(http.MethodPost, "/v1/direct/checkout", strings.NewReader(`{"productID":"pro.yearly"}`))
	response := httptest.NewRecorder()

	handler.HandleCheckout(response, request)

	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503, got %d: %s", response.Code, response.Body.String())
	}
}

func TestStaticPaymentProviderCustomerPortal(t *testing.T) {
	paymentProvider := provider.NewStaticPaymentProvider("creem", "", "https://pay.starcat.test/portal")

	response, err := paymentProvider.CustomerPortal(context.Background(), model.CustomerPortalRequest{Email: "user@example.com"})
	if err != nil {
		t.Fatalf("expected portal URL, got error: %v", err)
	}
	if response.Provider != "creem" || response.URL != "https://pay.starcat.test/portal" {
		t.Fatalf("unexpected portal response: %+v", response)
	}
}
