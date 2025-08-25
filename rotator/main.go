package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"os"

	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
)

var (
	secretID string
	sm       *secretsmanager.Client
)

func randToken(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	// URL-safe, no padding
	s := base64.RawURLEncoding.EncodeToString(b)
	return s, nil
}

func handler(ctx context.Context) (string, error) {
	token, err := randToken(32)
	if err != nil {
		return "", err
	}
	_, err = sm.PutSecretValue(ctx, &secretsmanager.PutSecretValueInput{
		SecretId:     &secretID,
		SecretString: &token,
	})
	if err != nil {
		return "", err
	}
	return token, nil
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
