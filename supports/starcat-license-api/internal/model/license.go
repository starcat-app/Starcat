// Package model 定义 License API 的请求和响应模型。
package model

import "time"

type ActivateRequest struct {
	LicenseKey string `json:"licenseKey"`
	DeviceID   string `json:"deviceID"`
	AppVersion string `json:"appVersion"`
}

type ValidateRequest struct {
	LicenseKey string `json:"licenseKey"`
	InstanceID string `json:"instanceID"`
	DeviceID   string `json:"deviceID"`
	AppVersion string `json:"appVersion"`
}

type DeactivateRequest struct {
	LicenseKey string `json:"licenseKey"`
	InstanceID string `json:"instanceID"`
	DeviceID   string `json:"deviceID"`
}

type LicenseSnapshot struct {
	Status           string     `json:"status"`
	Provider         string     `json:"provider"`
	ProductID        string     `json:"productID,omitempty"`
	InstanceID       string     `json:"instanceID,omitempty"`
	LicenseKeySuffix string     `json:"licenseKeySuffix,omitempty"`
	ExpiresAt        *time.Time `json:"expiresAt,omitempty"`
	ValidatedAt      time.Time  `json:"validatedAt"`
}

type ErrorResponse struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}
