// ddns/main.go
package main

import (
	"context"
	"encoding/json"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	r53 "github.com/aws/aws-sdk-go-v2/service/route53"
	r53Types "github.com/aws/aws-sdk-go-v2/service/route53/types"
	sm "github.com/aws/aws-sdk-go-v2/service/secretsmanager"
)

type result struct {
	Status string `json:"status"`
	Record string `json:"record"`
	Type   string `json:"type,omitempty"`
	Old    string `json:"old,omitempty"`
	New    string `json:"new,omitempty"`
	IP     string `json:"ip,omitempty"`
	TTL    int64  `json:"ttl"`
	Msg    string `json:"msg,omitempty"`
}

var (
	zoneID, recordName, secretARN string
	ttl                           int64
	r53c                          *r53.Client
	smc                           *sm.Client

	tokCache struct {
		mu  sync.RWMutex
		val string
		exp time.Time
	}
)

func ensureDot(name string) string {
	if !strings.HasSuffix(name, ".") {
		return name + "."
	}
	return name
}

func ipVersion(ip string) string {
	parsed := net.ParseIP(strings.TrimSpace(ip))
	if parsed == nil {
		return ""
	}
	if parsed.To4() != nil {
		return "A"
	}
	return "AAAA"
}

func getCallerIP(req events.APIGatewayV2HTTPRequest) (string, string) {
	if req.RequestContext.HTTP.SourceIP != "" {
		return req.RequestContext.HTTP.SourceIP, ipVersion(req.RequestContext.HTTP.SourceIP)
	}
	// fallback: X-Forwarded-For
	if v := req.Headers["x-forwarded-for"]; v != "" {
		ip := strings.TrimSpace(strings.Split(v, ",")[0])
		return ip, ipVersion(ip)
	}
	return "", ""
}

func getSharedToken(ctx context.Context) (string, error) {
	tokCache.mu.RLock()
	if time.Now().Before(tokCache.exp) && tokCache.val != "" {
		v := tokCache.val
		tokCache.mu.RUnlock()
		return v, nil
	}
	tokCache.mu.RUnlock()

	out, err := smc.GetSecretValue(ctx, &sm.GetSecretValueInput{SecretId: aws.String(secretARN)})
	if err != nil {
		return "", err
	}
	v := strings.TrimSpace(aws.ToString(out.SecretString))

	tokCache.mu.Lock()
	tokCache.val = v
	tokCache.exp = time.Now().Add(30 * time.Second)
	tokCache.mu.Unlock()
	return v, nil
}

func currentRecord(ctx context.Context, rtype string) (string, error) {
	out, err := r53c.ListResourceRecordSets(ctx, &r53.ListResourceRecordSetsInput{
		HostedZoneId:    aws.String(zoneID),
		StartRecordName: aws.String(recordName),
		StartRecordType: r53Types.RRType(rtype),
		MaxItems:        aws.Int32(1),
	})
	if err != nil || out == nil || len(out.ResourceRecordSets) == 0 {
		return "", err
	}
	rrset := out.ResourceRecordSets[0]
	if aws.ToString(rrset.Name) != ensureDot(recordName) || string(rrset.Type) != rtype {
		return "", nil
	}
	if len(rrset.ResourceRecords) == 0 {
		return "", nil
	}
	return aws.ToString(rrset.ResourceRecords[0].Value), nil
}

func upsert(ctx context.Context, rtype, value string) error {
	_, err := r53c.ChangeResourceRecordSets(ctx, &r53.ChangeResourceRecordSetsInput{
		HostedZoneId: aws.String(zoneID),
		ChangeBatch: &r53Types.ChangeBatch{
			Changes: []r53Types.Change{
				{
					Action: r53Types.ChangeActionUpsert,
					ResourceRecordSet: &r53Types.ResourceRecordSet{
						Name: aws.String(recordName),
						Type: r53Types.RRType(rtype),
						TTL:  aws.Int64(ttl),
						ResourceRecords: []r53Types.ResourceRecord{
							{Value: aws.String(value)},
						},
					},
				},
			},
			Comment: aws.String("ddns-lambda"),
		},
	})
	return err
}

func handler(ctx context.Context, req events.APIGatewayV2HTTPRequest) (events.APIGatewayV2HTTPResponse, error) {
	// --- token check (X-Token header or ?token=) ---
	got := strings.TrimSpace(req.Headers["x-token"])
	if got == "" {
		if t, ok := req.QueryStringParameters["token"]; ok {
			got = strings.TrimSpace(t)
		}
	}
	want, err := getSharedToken(ctx)
	if err != nil {
		body, _ := json.Marshal(result{Status: "error", Record: recordName, TTL: ttl, Msg: "secret read failed"})
		return events.APIGatewayV2HTTPResponse{StatusCode: 500, Body: string(body), Headers: map[string]string{"Content-Type": "application/json"}}, nil
	}
	if got == "" || got != want {
		return events.APIGatewayV2HTTPResponse{StatusCode: 401, Body: `{"message":"Unauthorized"}`, Headers: map[string]string{"Content-Type": "application/json"}}, nil
	}

	// --- ddns logic ---
	ip, rtype := getCallerIP(req)
	if ip == "" || rtype == "" {
		body, _ := json.Marshal(result{Status: "error", Record: recordName, TTL: ttl, Msg: "could not determine caller IP"})
		return events.APIGatewayV2HTTPResponse{StatusCode: 400, Body: string(body), Headers: map[string]string{"Content-Type": "application/json"}}, nil
	}
	cur, _ := currentRecord(ctx, rtype)
	if cur == ip {
		body, _ := json.Marshal(result{Status: "nochange", Record: recordName, Type: rtype, IP: ip, TTL: ttl})
		return events.APIGatewayV2HTTPResponse{StatusCode: 200, Body: string(body), Headers: map[string]string{"Content-Type": "application/json"}}, nil
	}
	if err := upsert(ctx, rtype, ip); err != nil {
		body, _ := json.Marshal(result{Status: "error", Record: recordName, Type: rtype, TTL: ttl, Msg: err.Error()})
		return events.APIGatewayV2HTTPResponse{StatusCode: 500, Body: string(body), Headers: map[string]string{"Content-Type": "application/json"}}, nil
	}
	body, _ := json.Marshal(result{Status: "updated", Record: recordName, Type: rtype, Old: cur, New: ip, TTL: ttl})
	return events.APIGatewayV2HTTPResponse{StatusCode: 200, Body: string(body), Headers: map[string]string{"Content-Type": "application/json"}}, nil
}

func main() {
	zoneID = os.Getenv("HOSTED_ZONE_ID")
	recordName = os.Getenv("RECORD_NAME")
	secretARN = os.Getenv("DDNS_SHARED_TOKEN_SECRET_ARN")
	ttl = 60
	if t := os.Getenv("TTL"); t != "" {
		if v, e := strconv.ParseInt(t, 10, 64); e == nil {
			ttl = v
		}
	}
	cfg, err := config.LoadDefaultConfig(context.Background())
	if err != nil {
		panic(err)
	}
	r53c = r53.NewFromConfig(cfg)
	smc = sm.NewFromConfig(cfg)
	lambda.Start(handler)
}
