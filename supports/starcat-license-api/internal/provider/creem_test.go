package provider

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/dong4j/starcat-license-api/internal/model"
)

func TestCreemProviderActivateNormalizesSnapshot(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("x-api-key") != "creem_test" {
			t.Fatalf("missing x-api-key")
		}
		if r.URL.Path != "/licenses/activate" {
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"product_id": "prod_123",
			"status":     "active",
			"key":        "ABCD-EFGH-IJKL",
			"instance": []map[string]any{
				{"id": "inst_123", "status": "active"},
			},
		})
	}))
	defer server.Close()

	provider := NewCreemProvider(server.URL, "creem_test", server.Client())
	snapshot, err := provider.Activate(context.Background(), model.ActivateRequest{
		LicenseKey: "ABCD-EFGH-IJKL",
		DeviceID:   "macbook",
	})
	if err != nil {
		t.Fatalf("Activate returned error: %v", err)
	}
	if snapshot.Status != "active" || snapshot.Provider != "creem" || snapshot.ProductID != "prod_123" {
		t.Fatalf("unexpected snapshot: %#v", snapshot)
	}
	if snapshot.InstanceID != "inst_123" || snapshot.LicenseKeySuffix != "IJKL" {
		t.Fatalf("unexpected identity fields: %#v", snapshot)
	}
}

func TestCreemProviderRequiresAPIKey(t *testing.T) {
	provider := NewCreemProvider("https://example.com", "", nil)
	_, err := provider.Validate(context.Background(), model.ValidateRequest{
		LicenseKey: "key",
		InstanceID: "inst",
	})
	if err != ErrProviderNotConfigured {
		t.Fatalf("expected ErrProviderNotConfigured, got %v", err)
	}
}
