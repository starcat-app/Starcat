// Package middleware 提供 HTTP 中间件。
package middleware

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/dong4j/starcat-license-api/internal/model"
)

type BearerAuth struct {
	allowedKeys map[string]bool
}

func NewBearerAuth(keys []string) *BearerAuth {
	allowed := make(map[string]bool, len(keys))
	for _, key := range keys {
		key = strings.TrimSpace(key)
		if key != "" {
			allowed[key] = true
		}
	}
	return &BearerAuth{allowedKeys: allowed}
}

func (a *BearerAuth) Wrap(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		header := r.Header.Get("Authorization")
		if !strings.HasPrefix(header, "Bearer ") {
			writeAuthError(w)
			return
		}
		token := strings.TrimSpace(strings.TrimPrefix(header, "Bearer "))
		if !a.allowedKeys[token] {
			writeAuthError(w)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func writeAuthError(w http.ResponseWriter) {
	w.Header().Set("WWW-Authenticate", "Bearer")
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusUnauthorized)
	_ = json.NewEncoder(w).Encode(model.ErrorResponse{
		Code:    "UNAUTHORIZED",
		Message: "invalid API key",
	})
}
