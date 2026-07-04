package handler

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/dong4j/starcat-license-api/internal/model"
	"github.com/dong4j/starcat-license-api/internal/provider"
)

type LicenseHandler struct {
	provider provider.LicenseProvider
}

func NewLicenseHandler(provider provider.LicenseProvider) *LicenseHandler {
	return &LicenseHandler{provider: provider}
}

func (h *LicenseHandler) HandleActivate(w http.ResponseWriter, r *http.Request) {
	var request model.ActivateRequest
	if !decodeJSON(w, r, &request) {
		return
	}
	if strings.TrimSpace(request.LicenseKey) == "" || strings.TrimSpace(request.DeviceID) == "" {
		writeError(w, http.StatusBadRequest, "BAD_REQUEST", "licenseKey and deviceID are required")
		return
	}
	snapshot, err := h.provider.Activate(r.Context(), request)
	writeProviderResult(w, snapshot, err)
}

func (h *LicenseHandler) HandleValidate(w http.ResponseWriter, r *http.Request) {
	var request model.ValidateRequest
	if !decodeJSON(w, r, &request) {
		return
	}
	if strings.TrimSpace(request.LicenseKey) == "" || strings.TrimSpace(request.InstanceID) == "" {
		writeError(w, http.StatusBadRequest, "BAD_REQUEST", "licenseKey and instanceID are required")
		return
	}
	snapshot, err := h.provider.Validate(r.Context(), request)
	writeProviderResult(w, snapshot, err)
}

func (h *LicenseHandler) HandleDeactivate(w http.ResponseWriter, r *http.Request) {
	var request model.DeactivateRequest
	if !decodeJSON(w, r, &request) {
		return
	}
	if strings.TrimSpace(request.LicenseKey) == "" || strings.TrimSpace(request.InstanceID) == "" {
		writeError(w, http.StatusBadRequest, "BAD_REQUEST", "licenseKey and instanceID are required")
		return
	}
	snapshot, err := h.provider.Deactivate(r.Context(), request)
	writeProviderResult(w, snapshot, err)
}

func decodeJSON(w http.ResponseWriter, r *http.Request, target any) bool {
	if err := json.NewDecoder(r.Body).Decode(target); err != nil {
		writeError(w, http.StatusBadRequest, "BAD_JSON", "invalid JSON body")
		return false
	}
	return true
}

func writeProviderResult(w http.ResponseWriter, snapshot model.LicenseSnapshot, err error) {
	if err == nil {
		writeJSON(w, snapshot)
		return
	}
	if errors.Is(err, provider.ErrProviderNotConfigured) {
		writeError(w, http.StatusServiceUnavailable, "PROVIDER_NOT_CONFIGURED", "license provider is not configured")
		return
	}
	writeError(w, http.StatusBadGateway, "PROVIDER_ERROR", err.Error())
}
