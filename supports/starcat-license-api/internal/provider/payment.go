// Package provider contains the vendor boundary for Direct distribution.
//
// Payment providers are separated from HTTP handlers so future gateways can be
// added without changing Starcat's public License API contract.
package provider

import (
	"context"
	"errors"

	"github.com/dong4j/starcat-license-api/internal/model"
)

// ErrPaymentNotConfigured means the selected payment provider is missing the
// configuration required to create a user-facing payment URL.
var ErrPaymentNotConfigured = errors.New("payment provider is not configured")

// PaymentProvider hides provider-specific checkout and portal creation details.
// The first implementation returns configured Creem URLs, but the interface is
// intentionally provider-neutral because Starcat may support multiple gateways.
type PaymentProvider interface {
	Checkout(ctx context.Context, request model.CheckoutRequest) (model.PaymentURLResponse, error)
	CustomerPortal(ctx context.Context, request model.CustomerPortalRequest) (model.PaymentURLResponse, error)
}

// StaticPaymentProvider is the Direct v1 adapter for providers whose hosted
// checkout and customer portal URLs are configured outside this service.
type StaticPaymentProvider struct {
	providerName      string
	checkoutURL       string
	customerPortalURL string
}

func NewStaticPaymentProvider(providerName, checkoutURL, customerPortalURL string) *StaticPaymentProvider {
	return &StaticPaymentProvider{
		providerName:      providerName,
		checkoutURL:       checkoutURL,
		customerPortalURL: customerPortalURL,
	}
}

func (p *StaticPaymentProvider) Checkout(ctx context.Context, request model.CheckoutRequest) (model.PaymentURLResponse, error) {
	if p.checkoutURL == "" {
		return model.PaymentURLResponse{}, ErrPaymentNotConfigured
	}
	return model.PaymentURLResponse{Provider: p.providerName, URL: p.checkoutURL}, nil
}

func (p *StaticPaymentProvider) CustomerPortal(ctx context.Context, request model.CustomerPortalRequest) (model.PaymentURLResponse, error) {
	if p.customerPortalURL == "" {
		return model.PaymentURLResponse{}, ErrPaymentNotConfigured
	}
	return model.PaymentURLResponse{Provider: p.providerName, URL: p.customerPortalURL}, nil
}
