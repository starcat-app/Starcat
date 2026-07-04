package model

type CheckoutRequest struct {
	ProductID     string `json:"productID"`
	CustomerEmail string `json:"customerEmail,omitempty"`
}

type CustomerPortalRequest struct {
	CustomerID string `json:"customerID,omitempty"`
	Email      string `json:"email,omitempty"`
}

type PaymentURLResponse struct {
	Provider string `json:"provider"`
	URL      string `json:"url"`
}
