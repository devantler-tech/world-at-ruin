package dynamowitness

import (
	"context"
	"errors"
	"os/exec"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"

	"github.com/devantler-tech/world-at-ruin/server/internal/custodywitness"
)

const tableName = "war-custody-witness"

var created = time.Unix(1700000000, 0).UTC()

// fakeAPI evaluates exactly the two condition expressions the adapter may
// send, so a request the adapter shapes differently fails loudly instead of
// being accepted.
type fakeAPI struct {
	mu        sync.Mutex
	tableID   string
	items     map[string]map[string]types.AttributeValue
	calls     int
	getInputs []*dynamodb.GetItemInput
	putErr    error
	getErr    error
	descErr   error
	descOut   *dynamodb.DescribeTableOutput
}

func newFakeAPI() *fakeAPI {
	return &fakeAPI{tableID: "table-a", items: map[string]map[string]types.AttributeValue{}}
}

func (f *fakeAPI) DescribeTable(_ context.Context, in *dynamodb.DescribeTableInput, _ ...func(*dynamodb.Options)) (*dynamodb.DescribeTableOutput, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	if aws.ToString(in.TableName) != tableName {
		return nil, errors.New("unexpected table name")
	}
	if f.descErr != nil || f.descOut != nil {
		return f.descOut, f.descErr
	}
	return &dynamodb.DescribeTableOutput{Table: &types.TableDescription{TableId: aws.String(f.tableID), CreationDateTime: aws.Time(created)}}, nil
}

func keyOf(item map[string]types.AttributeValue) (string, bool) {
	key, ok := item[KeyAttribute].(*types.AttributeValueMemberS)
	if !ok || len(item) != 1 && len(item) != 2 {
		return "", false
	}
	return key.Value, true
}

func (f *fakeAPI) GetItem(_ context.Context, in *dynamodb.GetItemInput, _ ...func(*dynamodb.Options)) (*dynamodb.GetItemOutput, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	f.getInputs = append(f.getInputs, in)
	if f.getErr != nil {
		return nil, f.getErr
	}
	key, ok := keyOf(in.Key)
	if !ok || len(in.Key) != 1 || aws.ToString(in.TableName) != tableName {
		return nil, errors.New("malformed get request")
	}
	return &dynamodb.GetItemOutput{Item: f.items[key]}, nil
}

func (f *fakeAPI) PutItem(_ context.Context, in *dynamodb.PutItemInput, _ ...func(*dynamodb.Options)) (*dynamodb.PutItemOutput, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	if f.putErr != nil {
		return nil, f.putErr
	}
	key, ok := keyOf(in.Item)
	if !ok || len(in.Item) != 2 || aws.ToString(in.TableName) != tableName {
		return nil, errors.New("malformed put request")
	}
	current, found := f.items[key]
	switch aws.ToString(in.ConditionExpression) {
	case "attribute_not_exists(#key)":
		if in.ExpressionAttributeNames["#key"] != KeyAttribute || len(in.ExpressionAttributeValues) != 0 {
			return nil, errors.New("malformed create condition")
		}
		if found {
			return nil, &types.ConditionalCheckFailedException{Message: aws.String("exists")}
		}
	case "#record = :expected":
		if in.ExpressionAttributeNames["#record"] != RecordAttribute {
			return nil, errors.New("malformed advance condition")
		}
		want, ok := in.ExpressionAttributeValues[":expected"].(*types.AttributeValueMemberS)
		if !ok {
			return nil, errors.New("malformed advance value")
		}
		stored, isString := current[RecordAttribute].(*types.AttributeValueMemberS)
		if !found || !isString || stored.Value != want.Value {
			return nil, &types.ConditionalCheckFailedException{Message: aws.String("differs")}
		}
	default:
		return nil, errors.New("unconditional or unknown write")
	}
	f.items[key] = in.Item
	return &dynamodb.PutItemOutput{}, nil
}

var (
	lifetime  = strings.Repeat("a", 64)
	enrolled  = custodywitness.Record{LifetimeKey: lifetime, Stage: custodywitness.StageEnrolled, EnrollmentPin: strings.Repeat("b", 64)}
	custody   = custodywitness.Record{LifetimeKey: lifetime, Stage: custodywitness.StageCustody, EnrollmentPin: enrolled.EnrollmentPin, CustodyPin: strings.Repeat("c", 64)}
	tombstone = custodywitness.Record{LifetimeKey: lifetime, Stage: custodywitness.StageTombstone, EnrollmentPin: enrolled.EnrollmentPin, CustodyPin: custody.CustodyPin, TombstonePin: strings.Repeat("d", 64)}
)

func newTable(t *testing.T, api API) *Table {
	t.Helper()
	table, err := New(Config{Enabled: true, TableName: tableName, API: api})
	if err != nil {
		t.Fatal(err)
	}
	return table
}

func newWitness(t *testing.T, api API) *custodywitness.Client {
	t.Helper()
	client, err := custodywitness.New(custodywitness.Config{
		Enabled:  true,
		Table:    newTable(t, api),
		Identity: custodywitness.TableIdentity{ID: "table-a", CreatedAt: created},
	})
	if err != nil {
		t.Fatal(err)
	}
	return client
}

func TestNewRefusesDisabledOrIncompleteConfigurationWithoutCalls(t *testing.T) {
	api := newFakeAPI()
	for name, cfg := range map[string]Config{
		"disabled":   {TableName: tableName, API: api},
		"no table":   {Enabled: true, API: api},
		"blank name": {Enabled: true, TableName: "war witness", API: api},
		"no api":     {Enabled: true, TableName: tableName},
	} {
		if table, err := New(cfg); table != nil || !errors.Is(err, ErrUnconfigured) {
			t.Fatal(name, "accepted")
		}
	}
	if api.calls != 0 {
		t.Fatal("an unconfigured adapter reached DynamoDB")
	}
}

func TestForwardChainThroughTheAdapter(t *testing.T) {
	ctx := t.Context()
	api := newFakeAPI()
	witness := newWitness(t, api)
	previous := custodywitness.Record{}
	for _, next := range []custodywitness.Record{enrolled, custody, tombstone} {
		ack, err := witness.Write(ctx, previous, next)
		if err != nil || ack != next {
			t.Fatal("stage refused", next.Stage, err)
		}
		if verdict := witness.Compare(ctx, next); verdict != custodywitness.Verified {
			t.Fatal("stored stage not verified", next.Stage, verdict)
		}
		previous = next
	}
	for _, in := range api.getInputs {
		if !aws.ToBool(in.ConsistentRead) {
			t.Fatal("a witness read was eventually consistent")
		}
	}
	if verdict := witness.Compare(ctx, custody); verdict != custodywitness.WitnessAhead {
		t.Fatal("rolled-back custody not detected", verdict)
	}
}

func TestRefusedConditionsMapToConditionFailedAndChangeNothing(t *testing.T) {
	ctx := t.Context()
	api := newFakeAPI()
	table := newTable(t, api)
	first, _ := custodywitness.EncodeRecord(enrolled)
	if err := table.Put(ctx, lifetime, "", first); err != nil {
		t.Fatal(err)
	}
	other := enrolled
	other.EnrollmentPin = strings.Repeat("e", 64)
	second, _ := custodywitness.EncodeRecord(other)
	if err := table.Put(ctx, lifetime, "", second); !errors.Is(err, custodywitness.ErrConditionFailed) {
		t.Fatal("second enrollment not refused", err)
	}
	next, _ := custodywitness.EncodeRecord(custody)
	if err := table.Put(ctx, lifetime, second, next); !errors.Is(err, custodywitness.ErrConditionFailed) {
		t.Fatal("wrong previous record not refused", err)
	}
	if err := table.Put(ctx, strings.Repeat("f", 64), first, next); !errors.Is(err, custodywitness.ErrConditionFailed) {
		t.Fatal("advance of an absent record not refused", err)
	}
	if stored, found, err := table.Get(ctx, lifetime); err != nil || !found || stored != first {
		t.Fatal("a refused write changed the record")
	}
}

func TestServiceErrorsStayAmbiguous(t *testing.T) {
	ctx := t.Context()
	api := newFakeAPI()
	api.putErr = errors.New("connection reset")
	table := newTable(t, api)
	err := table.Put(ctx, lifetime, "", "x")
	if err == nil || errors.Is(err, custodywitness.ErrConditionFailed) {
		t.Fatal("an ambiguous write was reported as settled", err)
	}
	api.getErr = errors.New("throttled")
	if _, _, err := table.Get(ctx, lifetime); err == nil {
		t.Fatal("a failed read succeeded")
	}
	if verdict := newWitness(t, api).Compare(ctx, enrolled); verdict != custodywitness.Unavailable {
		t.Fatal("a failed read was classified", verdict)
	}
}

func TestMalformedItemsAreConflictingNotAbsent(t *testing.T) {
	ctx := t.Context()
	value, _ := custodywitness.EncodeRecord(enrolled)
	for name, item := range map[string]map[string]types.AttributeValue{
		"missing record": {KeyAttribute: &types.AttributeValueMemberS{Value: lifetime}},
		"binary record":  {KeyAttribute: &types.AttributeValueMemberS{Value: lifetime}, RecordAttribute: &types.AttributeValueMemberB{Value: []byte(value)}},
		"extra field": {
			KeyAttribute: &types.AttributeValueMemberS{Value: lifetime}, RecordAttribute: &types.AttributeValueMemberS{Value: value},
			"expires": &types.AttributeValueMemberN{Value: "1"},
		},
	} {
		api := newFakeAPI()
		api.items[lifetime] = item
		if verdict := newWitness(t, api).Compare(ctx, enrolled); verdict != custodywitness.Conflicting {
			t.Fatal(name, "classified as", verdict)
		}
	}
}

func TestIdentityComesFromTheDescribedTable(t *testing.T) {
	ctx := t.Context()
	api := newFakeAPI()
	api.tableID = "table-b"
	if verdict := newWitness(t, api).Compare(ctx, enrolled); verdict != custodywitness.TableReplaced {
		t.Fatal("a recreated table was accepted", verdict)
	}
	for name, out := range map[string]*dynamodb.DescribeTableOutput{
		"no table":   {},
		"no id":      {Table: &types.TableDescription{CreationDateTime: aws.Time(created)}},
		"no created": {Table: &types.TableDescription{TableId: aws.String("table-a")}},
	} {
		api := newFakeAPI()
		api.descOut = out
		if _, err := newTable(t, api).Identity(ctx); err == nil {
			t.Fatal(name, "accepted")
		}
	}
}

// Normal commands, the serving plugin and the release tools never compose the
// adapter or the AWS SDK, with or without the native trial build tag.
func TestNormalArtifactsDoNotComposeTheAdapter(t *testing.T) {
	ctx, cancel := context.WithTimeout(t.Context(), 4*time.Minute)
	defer cancel()
	for tags, cmd := range map[string]*exec.Cmd{
		"default":          exec.CommandContext(ctx, "go", "list", "-mod=readonly", "-tags=", "-deps", "./cmd/..."),
		"war_native_trial": exec.CommandContext(ctx, "go", "list", "-mod=readonly", "-tags=war_native_trial", "-deps", "./cmd/..."),
	} {
		cmd.Dir = "../../.."
		raw, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("normal import observation incomplete (%s): %v %s", tags, err, raw)
		}
		for _, forbidden := range []string{"/internal/custodywitness", "github.com/aws/"} {
			if strings.Contains(string(raw), forbidden) {
				t.Fatal("a normal artifact composed", forbidden, tags)
			}
		}
	}
}
