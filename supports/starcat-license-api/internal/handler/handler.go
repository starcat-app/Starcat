// Package handler 提供 HTTP handler 公共工具。
package handler

import (
	"encoding/json"
	"log"
	"net/http"

	"github.com/dong4j/starcat-license-api/internal/model"
)

func writeJSON[T any](w http.ResponseWriter, data T) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	if err := json.NewEncoder(w).Encode(data); err != nil {
		log.Printf("[handler] failed to encode response: %v", err)
	}
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(model.ErrorResponse{
		Code:    code,
		Message: message,
	})
}
