package main

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"html/template"
	"log"
	"math/big"
	"net/http"
	"os"
	"sync"
	"time"
)

type ShareRepoDTO struct {
	FullName    string   `json:"fullName"`
	Description *string  `json:"description"`
	Language    *string  `json:"language"`
	StarsCount  int      `json:"starsCount"`
	ForksCount  int      `json:"forksCount"`
	Topics      []string `json:"topics"`
	Homepage    *string  `json:"homepage"`
	URL         string   `json:"url"`
}

type ShareTagDTO struct {
	Name       string   `json:"name"`
	Confidence *float64 `json:"confidence"`
}

type ShareAISummaryDTO struct {
	OneLiner      string        `json:"oneLiner"`
	Summary       string        `json:"summary"`
	Platforms     []string      `json:"platforms"`
	SuitableFor   []string      `json:"suitableFor"`
	Strengths     []string      `json:"strengths"`
	Risks         []string      `json:"risks"`
	SuggestedTags []ShareTagDTO `json:"suggestedTags"`
}

type ShareRepoRequest struct {
	Repo      ShareRepoDTO      `json:"repo"`
	AISummary ShareAISummaryDTO `json:"aiSummary"`
}

type ShareResponseDTO struct {
	ShareUrl  string `json:"shareUrl"`
	ExpiresAt string `json:"expiresAt"`
}

type ShareData struct {
	ID        string           `json:"id"`
	Request   ShareRepoRequest `json:"request"`
	CreatedAt time.Time        `json:"createdAt"`
	ExpiresAt time.Time        `json:"expiresAt"`
}

var (
	storeFile = "data.json"
	mu        sync.RWMutex
	store     = make(map[string]ShareData)
	baseURL   = "https://starcat.app" // 可通过环境变量 BASE_URL 覆盖
	templates *template.Template
)

func init() {
	if url := os.Getenv("BASE_URL"); url != "" {
		baseURL = url
	}
	// 加载存储
	if b, err := os.ReadFile(storeFile); err == nil {
		json.Unmarshal(b, &store)
	}
}

func saveStore() {
	mu.RLock()
	defer mu.RUnlock()
	b, _ := json.MarshalIndent(store, "", "  ")
	os.WriteFile(storeFile, b, 0644)
}

func generateID(length int) string {
	const charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	b := make([]byte, length)
	for i := range b {
		n, _ := rand.Int(rand.Reader, big.NewInt(int64(len(charset))))
		b[i] = charset[n.Int64()]
	}
	return string(b)
}

func handleShareAPI(w http.ResponseWriter, r *http.Request) {
	var req ShareRepoRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	id := generateID(8)
	expiresAt := time.Now().AddDate(0, 1, 0) // 1个月有效期

	data := ShareData{
		ID:        id,
		Request:   req,
		CreatedAt: time.Now(),
		ExpiresAt: expiresAt,
	}

	mu.Lock()
	store[id] = data
	mu.Unlock()
	saveStore()

	resp := ShareResponseDTO{
		ShareUrl:  fmt.Sprintf("%s/s/%s", baseURL, id),
		ExpiresAt: expiresAt.Format(time.RFC3339),
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func handleShareView(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	
	mu.RLock()
	data, ok := store[id]
	mu.RUnlock()

	if !ok {
		http.NotFound(w, r)
		return
	}

	err := templates.ExecuteTemplate(w, "share.html", data)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}

func main() {
	if err := os.MkdirAll("templates", 0755); err != nil {
		log.Fatal(err)
	}

	var err error
	templates, err = template.ParseGlob("templates/*.html")
	if err != nil {
		log.Fatalf("Error parsing templates: %v", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/share", handleShareAPI)
	mux.HandleFunc("GET /s/{id}", handleShareView)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	log.Printf("Starting server on port %s...", port)
	log.Fatal(http.ListenAndServe(":"+port, mux))
}
