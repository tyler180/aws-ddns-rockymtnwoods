// authorizer/main.go (diff)
package main

import (
	"context"
	"os"
	"strings"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	sm "github.com/aws/aws-sdk-go-v2/service/secretsmanager"
)

var (
	secretARN string
	smClient  *sm.Client
)

func getToken(ctx context.Context) (string, error) {
	out, err := smClient.GetSecretValue(ctx, &sm.GetSecretValueInput{
		SecretId: aws.String(secretARN),
	})
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(aws.ToString(out.SecretString)), nil
}

func firstIdentitySource(v []string) string {
	for _, s := range v {
		s = strings.TrimSpace(s)
		if s != "" {
			return s
		}
	}
	return ""
}

func handler(ctx context.Context, req events.APIGatewayV2CustomAuthorizerV2Request) (events.APIGatewayV2CustomAuthorizerSimpleResponse, error) {
	// 1) Prefer the value(s) API Gateway extracted
	got := firstIdentitySource(req.IdentitySource)

	// 2) Fallbacks (defense in depth)
	if got == "" {
		if h := req.Headers["x-token"]; h != "" {
			got = strings.TrimSpace(h)
		}
	}
	if got == "" {
		if qs := req.QueryStringParameters["token"]; qs != "" {
			got = strings.TrimSpace(qs)
		}
	}

	want, err := getToken(ctx)
	if err != nil {
		return events.APIGatewayV2CustomAuthorizerSimpleResponse{
			IsAuthorized: false,
			Context:      map[string]any{"reason": "secret_fetch_failed"},
		}, nil
	}

	isOK := (got != "" && got == want)
	return events.APIGatewayV2CustomAuthorizerSimpleResponse{
		IsAuthorized: isOK,
		Context:      map[string]any{"auth": "token"},
	}, nil
}

func main() {
	secretARN = os.Getenv("DDNS_SHARED_TOKEN_SECRET_ARN")
	if secretARN == "" {
		panic("DDNS_SHARED_TOKEN_SECRET_ARN is empty")
	}
	cfg, err := config.LoadDefaultConfig(context.Background())
	if err != nil {
		panic(err)
	}
	smClient = sm.NewFromConfig(cfg)
	lambda.Start(handler)
}
