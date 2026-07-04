package handler

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/dong4j/starcat-license-api/internal/model"
	"github.com/dong4j/starcat-license-api/internal/provider"
)

type PaymentHandler struct {
	provider provider.PaymentProvider
}

func NewPaymentHandler(provider provider.PaymentProvider) *PaymentHandler {
	return &PaymentHandler{
		provider: provider,
	}
}

func (h *PaymentHandler) HandleCheckout(w http.ResponseWriter, r *http.Request) {
	var request model.CheckoutRequest
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
		writeError(w, http.StatusBadRequest, "BAD_JSON", "invalid JSON body")
		return
	}
	response, err := h.provider.Checkout(r.Context(), request)
	if errors.Is(err, provider.ErrPaymentNotConfigured) {
		writeError(w, http.StatusServiceUnavailable, "CHECKOUT_NOT_CONFIGURED", "checkout URL is not configured")
		return
	}
	if err != nil {
		writeError(w, http.StatusBadGateway, "PAYMENT_PROVIDER_ERROR", "payment provider request failed")
		return
	}
	writeJSON(w, response)
}

func (h *PaymentHandler) HandleCustomerPortal(w http.ResponseWriter, r *http.Request) {
	var request model.CustomerPortalRequest
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
		writeError(w, http.StatusBadRequest, "BAD_JSON", "invalid JSON body")
		return
	}
	response, err := h.provider.CustomerPortal(r.Context(), request)
	if errors.Is(err, provider.ErrPaymentNotConfigured) {
		writeError(w, http.StatusServiceUnavailable, "CUSTOMER_PORTAL_NOT_CONFIGURED", "customer portal URL is not configured")
		return
	}
	if err != nil {
		writeError(w, http.StatusBadGateway, "PAYMENT_PROVIDER_ERROR", "payment provider request failed")
		return
	}
	writeJSON(w, response)
}
