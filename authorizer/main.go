package main

import (
	"context"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
)

var (
	secretID string
	sm       *secretsmanager.Client

	// tiny in-memory cache to reduce SM calls
	mu        sync.RWMutex
	cachedVal string
	cachedAt  time.Time
	ttl       = 30 * time.Second
)

type httpAuthRequest struct {
	Headers               map[string]string      `json:"headers"`
	QueryStringParameters map[string]string      `json:"queryStringParameters"`
	RequestContext        map[string]interface{} `json:"requestContext"` // unused, but present
}

type httpAuthResponse struct {
	IsAuthorized bool                   `json:"isAuthorized"`
	Context      map[string]interface{} `json:"context,omitempty"`
}

func getSecret(ctx context.Context) (string, error) {
	mu.RLock()
	if time.Since(cachedAt) < ttl && cachedVal != "" {
		val := cachedVal
		mu.RUnlock()
		return val, nil
	}
	mu.RUnlock()

	out, err := sm.GetSecretValue(ctx, &secretsmanager.GetSecretValueInput{
		SecretId: &secretID,
	})
	if err != nil {
		return "", err
	}
	val := awsString(out.SecretString)

	mu.Lock()
	cachedVal = val
	cachedAt = time.Now()
	mu.Unlock()
	return val, nil
}

func awsString(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

func handler(ctx context.Context, req httpAuthRequest) (httpAuthResponse, error) {
	want, err := getSecret(ctx)
	if err != nil {
		// deny on error
		return httpAuthResponse{IsAuthorized: false}, nil
	}

	// prefer header X-Token, fallback to query ?token=
	got := ""
	if v, ok := req.Headers["X-Token"]; ok {
		got = v
	}
	if got == "" {
		if v, ok := req.Headers["x-token"]; ok {
			got = v
		}
	}
	if got == "" && req.QueryStringParameters != nil {
		got = req.QueryStringParameters["token"]
	}

	ok := strings.TrimSpace(got) != "" && got == want
	return httpAuthResponse{
		IsAuthorized: ok,
	}, nil
}

func main() {
	secretID = os.Getenv("DDNS_SHARED_TOKEN_SECRET_ARN")
	if secretID == "" {
		panic("DDNS_SHARED_TOKEN_SECRET_ARN must be set")
	}
	cfg, err := config.LoadDefaultConfig(context.Background())
	if err != nil {
		panic(err)
	}
	sm = secretsmanager.NewFromConfig(cfg)
	lambda.Start(handler)
}
