// Package dynamowitness stores custody witness records in one Amazon DynamoDB
// table. It implements custodywitness.Table and nothing more: the forward-only
// rules, the pinned table identity and the comparison all stay in the
// custodywitness client.
//
// The adapter is default-off. New refuses a disabled or incomplete
// configuration, and the adapter never builds an AWS client, loads
// credentials or resolves a region itself: the caller injects an already
// configured DynamoDB API, so no AWS call happens without explicit
// configuration. The normal zone command, the serving plugin and the release
// artifacts do not import this package.
package dynamowitness

import (
	"context"
	"errors"
	"fmt"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"

	"github.com/devantler-tech/world-at-ruin/server/internal/custodywitness"
	"github.com/devantler-tech/world-at-ruin/server/internal/handoffidentity"
)

// The item shape: the partition key holds the ADR 0044 lifetime key and one
// string attribute holds the canonical schema-1 witness record.
const (
	KeyAttribute    = "lifetime_key"
	RecordAttribute = "record"
)

// ErrUnconfigured is returned by New for a disabled or incomplete
// configuration.
var ErrUnconfigured = errors.New("custody witness dynamodb: adapter not configured")

// API is the part of the DynamoDB client the adapter calls.
// *dynamodb.Client satisfies it.
type API interface {
	DescribeTable(ctx context.Context, in *dynamodb.DescribeTableInput, opts ...func(*dynamodb.Options)) (*dynamodb.DescribeTableOutput, error)
	GetItem(ctx context.Context, in *dynamodb.GetItemInput, opts ...func(*dynamodb.Options)) (*dynamodb.GetItemOutput, error)
	PutItem(ctx context.Context, in *dynamodb.PutItemInput, opts ...func(*dynamodb.Options)) (*dynamodb.PutItemOutput, error)
}

// Config opts into the adapter. TableName addresses the table; it is a
// replaceable name, which is why the client checks the table identity around
// every call.
type Config struct {
	Enabled   bool
	TableName string
	API       API
}

// Table is a custodywitness.Table backed by DynamoDB.
type Table struct {
	name string
	api  API
}

var _ custodywitness.Table = (*Table)(nil)

// New refuses a disabled configuration, an empty or oversized table name and
// a missing API, before any call is made.
func New(cfg Config) (*Table, error) {
	if !cfg.Enabled || cfg.API == nil || !handoffidentity.OpaqueUTF8(cfg.TableName, 1024) {
		return nil, ErrUnconfigured
	}
	return &Table{name: cfg.TableName, api: cfg.API}, nil
}

// Identity reads the table ID and creation time DynamoDB assigned. A table
// deleted and recreated, or restored from a backup, under the same name has a
// different ID, so the client never mistakes it for the pinned one.
func (t *Table) Identity(ctx context.Context) (custodywitness.TableIdentity, error) {
	out, err := t.api.DescribeTable(ctx, &dynamodb.DescribeTableInput{TableName: aws.String(t.name)})
	if err != nil {
		return custodywitness.TableIdentity{}, fmt.Errorf("custody witness dynamodb: describe table: %w", err)
	}
	if out == nil || out.Table == nil || out.Table.TableId == nil || out.Table.CreationDateTime == nil {
		return custodywitness.TableIdentity{}, errors.New("custody witness dynamodb: table description incomplete")
	}
	return custodywitness.TableIdentity{ID: *out.Table.TableId, CreatedAt: *out.Table.CreationDateTime}, nil
}

// Get reads the record for key with a strongly consistent read. An item that
// is not exactly the key and one string record for that key is reported as
// found with an unreadable value, so the client classifies it as conflicting
// rather than absent.
func (t *Table) Get(ctx context.Context, key string) (string, bool, error) {
	out, err := t.api.GetItem(ctx, &dynamodb.GetItemInput{
		TableName:      aws.String(t.name),
		Key:            map[string]types.AttributeValue{KeyAttribute: &types.AttributeValueMemberS{Value: key}},
		ConsistentRead: aws.Bool(true),
	})
	if err != nil {
		return "", false, fmt.Errorf("custody witness dynamodb: get item: %w", err)
	}
	if out == nil {
		return "", false, errors.New("custody witness dynamodb: empty get reply")
	}
	if out.Item == nil {
		return "", false, nil
	}
	return recordOf(out.Item, key), true, nil
}

// recordOf returns the stored record, or "" (which never decodes) when the
// item has any other shape.
func recordOf(item map[string]types.AttributeValue, key string) string {
	if len(item) != 2 {
		return ""
	}
	storedKey, ok := item[KeyAttribute].(*types.AttributeValueMemberS)
	if !ok || storedKey.Value != key {
		return ""
	}
	record, ok := item[RecordAttribute].(*types.AttributeValueMemberS)
	if !ok {
		return ""
	}
	return record.Value
}

// Put writes value under key in one conditional write: only when no item
// exists for an empty expected value, and otherwise only when the stored
// record equals expected. A refused condition returns
// custodywitness.ErrConditionFailed; every other error leaves the outcome
// unknown and is never reported as a refusal.
func (t *Table) Put(ctx context.Context, key, expected, value string) error {
	in := &dynamodb.PutItemInput{
		TableName: aws.String(t.name),
		Item: map[string]types.AttributeValue{
			KeyAttribute:    &types.AttributeValueMemberS{Value: key},
			RecordAttribute: &types.AttributeValueMemberS{Value: value},
		},
		ExpressionAttributeNames: map[string]string{"#key": KeyAttribute},
		ConditionExpression:      aws.String("attribute_not_exists(#key)"),
	}
	if expected != "" {
		in.ExpressionAttributeNames = map[string]string{"#record": RecordAttribute}
		in.ExpressionAttributeValues = map[string]types.AttributeValue{":expected": &types.AttributeValueMemberS{Value: expected}}
		in.ConditionExpression = aws.String("#record = :expected")
	}
	_, err := t.api.PutItem(ctx, in)
	var refused *types.ConditionalCheckFailedException
	switch {
	case err == nil:
		return nil
	case errors.As(err, &refused):
		return custodywitness.ErrConditionFailed
	default:
		return fmt.Errorf("custody witness dynamodb: put item: %w", err)
	}
}
