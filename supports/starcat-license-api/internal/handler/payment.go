package handler

import (
	"encoding/json"
	"net/http"

	"github.com/dong4j/starcat-license-api/internal/model"
)

type PaymentHandler struct {
	checkoutURL       string
	customerPortalURL string
}

func NewPaymentHandler(checkoutURL, customerPortalURL string) *PaymentHandler {
	return &PaymentHandler{
		checkoutURL:       checkoutURL,
		customerPortalURL: customerPortalURL,
	}
}

func (h *PaymentHandler) HandleCheckout(w http.ResponseWriter, r *http.Request) {
	var request model.CheckoutRequest
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
		writeError(w, http.StatusBadRequest, "BAD_JSON", "invalid JSON body")
		return
	}
	if h.checkoutURL == "" {
		writeError(w, http.StatusServiceUnavailable, "CHECKOUT_NOT_CONFIGURED", "checkout URL is not configured")
		return
	}
	writeJSON(w, model.PaymentURLResponse{Provider: "creem", URL: h.checkoutURL})
}

func (h *PaymentHandler) HandleCustomerPortal(w http.ResponseWriter, r *http.Request) {
	var request model.CustomerPortalRequest
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
		writeError(w, http.StatusBadRequest, "BAD_JSON", "invalid JSON body")
		return
	}
	if h.customerPortalURL == "" {
		writeError(w, http.StatusServiceUnavailable, "CUSTOMER_PORTAL_NOT_CONFIGURED", "customer portal URL is not configured")
		return
	}
	writeJSON(w, model.PaymentURLResponse{Provider: "creem", URL: h.customerPortalURL})
}
