// Package provider 定义支付/授权 provider 抽象。
package provider

import (
	"context"

	"github.com/dong4j/starcat-license-api/internal/model"
)

type LicenseProvider interface {
	Activate(ctx context.Context, request model.ActivateRequest) (model.LicenseSnapshot, error)
	Validate(ctx context.Context, request model.ValidateRequest) (model.LicenseSnapshot, error)
	Deactivate(ctx context.Context, request model.DeactivateRequest) (model.LicenseSnapshot, error)
}
