package main

import (
	"context"
	"encoding/json"
	"net/netip"
	"os"
	"strconv"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	route53 "github.com/aws/aws-sdk-go-v2/service/route53"
	"github.com/aws/aws-sdk-go-v2/service/route53/types"
)

var (
	r53          *route53.Client
	hostedZoneID string
	recordName   string // include trailing dot in env to be explicit, but we’ll add one if missing
	ttl          int64
	sharedToken  string
)

func ensureDot(name string) string {
	if len(name) == 0 {
		return name
	}
	if name[len(name)-1] == '.' {
		return name
	}
	return name + "."
}

func handler(ctx context.Context, req events.APIGatewayV2HTTPRequest) (events.APIGatewayV2HTTPResponse, error) {
	// Simple token check
	token := req.QueryStringParameters["token"]
	if token == "" || token != sharedToken {
		return events.APIGatewayV2HTTPResponse{StatusCode: 403, Body: "forbidden"}, nil
	}

	// Source IP from API Gateway HTTP API
	src := req.RequestContext.HTTP.SourceIP
	if src == "" {
		return events.APIGatewayV2HTTPResponse{StatusCode: 400, Body: "no source ip"}, nil
	}

	// Parse IP to decide record type
	ip, err := netip.ParseAddr(src)
	if err != nil {
		return events.APIGatewayV2HTTPResponse{StatusCode: 400, Body: "invalid source ip"}, nil
	}
	rType := types.RRTypeA
	if ip.Is6() {
		rType = types.RRTypeAaaa
	}

	// UPSERT the record
	_, err = r53.ChangeResourceRecordSets(ctx, &route53.ChangeResourceRecordSetsInput{
		HostedZoneId: aws.String(hostedZoneID),
		ChangeBatch: &types.ChangeBatch{
			Comment: aws.String("DDNS update from Lambda (Go)"),
			Changes: []types.Change{
				{
					Action: types.ChangeActionUpsert,
					ResourceRecordSet: &types.ResourceRecordSet{
						Name: aws.String(ensureDot(recordName)),
						Type: rType,
						TTL:  aws.Int64(ttl),
						ResourceRecords: []types.ResourceRecord{
							{Value: aws.String(src)},
						},
					},
				},
			},
		},
	})
	if err != nil {
		return events.APIGatewayV2HTTPResponse{StatusCode: 500, Body: "route53 error: " + err.Error()}, nil
	}

	resp := map[string]any{
		"updated": recordName,
		"type":    rType,
		"value":   src,
		"ttl":     ttl,
	}
	b, _ := json.Marshal(resp)
	return events.APIGatewayV2HTTPResponse{
		StatusCode: 200,
		Body:       string(b),
		Headers:    map[string]string{"Content-Type": "application/json"},
	}, nil
}

func main() {
	hostedZoneID = os.Getenv("HOSTED_ZONE_ID")
	recordName = os.Getenv("RECORD_NAME")
	sharedToken = os.Getenv("SHARED_TOKEN")
	ttlEnv := os.Getenv("TTL")

	if hostedZoneID == "" || recordName == "" || sharedToken == "" {
		panic("HOSTED_ZONE_ID, RECORD_NAME, and SHARED_TOKEN must be set")
	}
	if ttlEnv == "" {
		ttl = 60
	} else {
		if v, err := strconv.ParseInt(ttlEnv, 10, 64); err == nil {
			ttl = v
		} else {
			ttl = 60
		}
	}

	cfg, err := config.LoadDefaultConfig(context.Background())
	if err != nil {
		panic(err)
	}
	r53 = route53.NewFromConfig(cfg)

	lambda.Start(handler)
}
