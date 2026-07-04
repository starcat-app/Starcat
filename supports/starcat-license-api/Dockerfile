FROM golang:1.25-alpine AS builder

WORKDIR /app
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /out/license ./cmd/server

FROM alpine:3.22
WORKDIR /app
COPY --from=builder /out/license /app/license
EXPOSE 5010
CMD ["/app/license"]
