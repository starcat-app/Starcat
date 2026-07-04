// Package main 是 starcat-license-api 的入口。
//
// 本服务是 Direct 分发授权边界：客户端只和 Starcat License API 通信，
// Creem API Key、webhook secret 和后续多 provider 编排都留在服务端。
package main

import (
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"github.com/joho/godotenv"

	"github.com/dong4j/starcat-license-api/internal/handler"
	"github.com/dong4j/starcat-license-api/internal/middleware"
	"github.com/dong4j/starcat-license-api/internal/provider"
)

const defaultPort = "5010"

func main() {
	if err := godotenv.Load(); err != nil {
		log.Printf("[env] no .env file found, using OS environment only")
	} else {
		log.Printf("[env] .env loaded")
	}

	port := envOrDefault("PORT", defaultPort)
	apiKeys := requiredListEnv("API_KEYS")
	creemAPIKey := strings.TrimSpace(os.Getenv("CREEM_API_KEY"))
	creemBaseURL := envOrDefault("CREEM_API_BASE_URL", "https://test-api.creem.io/v1")
	webhookSecret := strings.TrimSpace(os.Getenv("CREEM_WEBHOOK_SECRET"))
	checkoutURL := strings.TrimSpace(os.Getenv("CREEM_CHECKOUT_URL"))
	customerPortalURL := strings.TrimSpace(os.Getenv("CREEM_CUSTOMER_PORTAL_URL"))

	licenseProvider := provider.NewCreemProvider(creemBaseURL, creemAPIKey, nil)
	authMW := middleware.NewBearerAuth(apiKeys)
	licenseHandler := handler.NewLicenseHandler(licenseProvider)
	paymentHandler := handler.NewPaymentHandler(checkoutURL, customerPortalURL)
	webhookHandler := handler.NewCreemWebhookHandler(webhookSecret)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", healthzHandler)
	mux.Handle("POST /v1/direct/checkout", authMW.Wrap(http.HandlerFunc(paymentHandler.HandleCheckout)))
	mux.Handle("POST /v1/direct/customer-portal", authMW.Wrap(http.HandlerFunc(paymentHandler.HandleCustomerPortal)))
	mux.Handle("POST /v1/direct/licenses/activate", authMW.Wrap(http.HandlerFunc(licenseHandler.HandleActivate)))
	mux.Handle("POST /v1/direct/licenses/validate", authMW.Wrap(http.HandlerFunc(licenseHandler.HandleValidate)))
	mux.Handle("POST /v1/direct/licenses/deactivate", authMW.Wrap(http.HandlerFunc(licenseHandler.HandleDeactivate)))
	mux.Handle("POST /v1/webhooks/direct/creem", http.HandlerFunc(webhookHandler.Handle))

	go func() {
		sigCh := make(chan os.Signal, 1)
		signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
		<-sigCh
		log.Println("Received shutdown signal, closing service...")
		os.Exit(0)
	}()

	log.Printf("starcat-license-api starting on port %s", port)
	log.Fatal(http.ListenAndServe(":"+port, middleware.CORS(mux)))
}

func healthzHandler(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

func requiredListEnv(key string) []string {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		log.Fatalf("%s env is required", key)
	}
	return strings.Split(raw, ",")
}

func envOrDefault(key, fallback string) string {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	return value
}
