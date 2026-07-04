// Package provider 的 Creem 实现。
package provider

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/dong4j/starcat-license-api/internal/model"
)

var ErrProviderNotConfigured = errors.New("license provider is not configured")

type CreemProvider struct {
	baseURL string
	apiKey  string
	client  *http.Client
}

func NewCreemProvider(baseURL, apiKey string, client *http.Client) *CreemProvider {
	if client == nil {
		client = http.DefaultClient
	}
	return &CreemProvider{
		baseURL: strings.TrimRight(baseURL, "/"),
		apiKey:  strings.TrimSpace(apiKey),
		client:  client,
	}
}

func (p *CreemProvider) Activate(ctx context.Context, request model.ActivateRequest) (model.LicenseSnapshot, error) {
	var response creemLicenseResponse
	err := p.post(ctx, "/licenses/activate", map[string]string{
		"key":           request.LicenseKey,
		"instance_name": request.DeviceID,
	}, &response)
	if err != nil {
		return model.LicenseSnapshot{}, err
	}
	return response.snapshot(), nil
}

func (p *CreemProvider) Validate(ctx context.Context, request model.ValidateRequest) (model.LicenseSnapshot, error) {
	var response creemLicenseResponse
	err := p.post(ctx, "/licenses/validate", map[string]string{
		"key":         request.LicenseKey,
		"instance_id": request.InstanceID,
	}, &response)
	if err != nil {
		return model.LicenseSnapshot{}, err
	}
	return response.snapshot(), nil
}

func (p *CreemProvider) Deactivate(ctx context.Context, request model.DeactivateRequest) (model.LicenseSnapshot, error) {
	var response creemLicenseResponse
	err := p.post(ctx, "/licenses/deactivate", map[string]string{
		"key":         request.LicenseKey,
		"instance_id": request.InstanceID,
	}, &response)
	if err != nil {
		return model.LicenseSnapshot{}, err
	}
	return response.snapshot(), nil
}

func (p *CreemProvider) post(ctx context.Context, path string, body any, target any) error {
	if p.apiKey == "" {
		return ErrProviderNotConfigured
	}
	payload, err := json.Marshal(body)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, p.baseURL+path, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-api-key", p.apiKey)

	resp, err := p.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("creem returned status %d", resp.StatusCode)
	}
	return json.NewDecoder(resp.Body).Decode(target)
}

type creemLicenseResponse struct {
	ProductID string         `json:"product_id"`
	Status    string         `json:"status"`
	Key       string         `json:"key"`
	ExpiresAt *time.Time     `json:"expires_at"`
	Instances creemInstances `json:"instance"`
}

type creemInstance struct {
	ID     string `json:"id"`
	Status string `json:"status"`
}

type creemInstances []creemInstance

func (i *creemInstances) UnmarshalJSON(data []byte) error {
	var items []creemInstance
	if err := json.Unmarshal(data, &items); err == nil {
		*i = items
		return nil
	}

	var item creemInstance
	if err := json.Unmarshal(data, &item); err != nil {
		return err
	}
	if item.ID == "" {
		*i = nil
	} else {
		*i = []creemInstance{item}
	}
	return nil
}

func (r creemLicenseResponse) snapshot() model.LicenseSnapshot {
	instanceID := ""
	if len(r.Instances) > 0 {
		instanceID = r.Instances[0].ID
	}
	return model.LicenseSnapshot{
		Status:           normalizeCreemStatus(r.Status),
		Provider:         "creem",
		ProductID:        r.ProductID,
		InstanceID:       instanceID,
		LicenseKeySuffix: suffix(r.Key, 4),
		ExpiresAt:        r.ExpiresAt,
		ValidatedAt:      time.Now().UTC(),
	}
}

func normalizeCreemStatus(status string) string {
	switch strings.ToLower(strings.TrimSpace(status)) {
	case "active":
		return "active"
	case "expired":
		return "expired"
	case "disabled":
		return "revoked"
	default:
		return "inactive"
	}
}

func suffix(value string, size int) string {
	if len(value) <= size {
		return value
	}
	return value[len(value)-size:]
}
