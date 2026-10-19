package dynamowitness

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"

	"github.com/devantler-tech/world-at-ruin/server/internal/custodywitness"
)

// sdkTable drives the real SDK client against a local endpoint that answers
// every request with the given status and JSON body, so the refusal mapping is
// checked against the SDK's own error decoding rather than a hand-built error.
func sdkTable(t *testing.T, status int, body string) *Table {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/x-amz-json-1.0")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(server.Close)
	client := dynamodb.New(dynamodb.Options{
		Region:       "eu-north-1",
		BaseEndpoint: aws.String(server.URL),
		Credentials: aws.CredentialsProviderFunc(func(context.Context) (aws.Credentials, error) {
			return aws.Credentials{AccessKeyID: "test", SecretAccessKey: "test"}, nil
		}),
		RetryMaxAttempts: 1,
	})
	return newTable(t, client)
}

func TestSDKConditionRefusalIsDecodedAsConditionFailed(t *testing.T) {
	table := sdkTable(t, http.StatusBadRequest,
		`{"__type":"com.amazonaws.dynamodb.v20120810#ConditionalCheckFailedException","message":"The conditional request failed"}`)
	if err := table.Put(t.Context(), lifetime, "", "x"); !errors.Is(err, custodywitness.ErrConditionFailed) {
		t.Fatal("the service's condition refusal was not recognised", err)
	}
}

func TestSDKOtherServiceErrorsStayAmbiguous(t *testing.T) {
	for name, body := range map[string]string{
		"throttled": `{"__type":"com.amazonaws.dynamodb.v20120810#ProvisionedThroughputExceededException","message":"slow down"}`,
		"cancelled": `{"__type":"com.amazonaws.dynamodb.v20120810#TransactionConflictException","message":"conflict"}`,
		"not json":  `<html>bad gateway</html>`,
	} {
		table := sdkTable(t, http.StatusBadRequest, body)
		err := table.Put(t.Context(), lifetime, "", "x")
		if err == nil || errors.Is(err, custodywitness.ErrConditionFailed) {
			t.Fatal(name, "was reported as settled", err)
		}
	}
}
