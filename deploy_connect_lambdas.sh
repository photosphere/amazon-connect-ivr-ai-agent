#!/usr/bin/env bash
#
# deploy_connect_lambdas.sh
#
# Interactively deploys two Lambda functions plus their contact flows into two
# Amazon Connect instances.
#
#   Instance #1, alias "Amazon Connect Customer Basic"
#     Lambda : ConnectGetCustomerModel - returns the ModelNumber of the most
#              recently stored record for a CustomerNumber
#     Flow   : Customer Inbound - AI IVR and Agent Transfer.json
#
#   Instance #2, alias "Amazon Connect Customer"
#     Lambda : ConnectSaveCustomerModel - writes {CustomerNumber, ModelNumber}
#              into DynamoDB (auto-creates the table if missing)
#     Flow   : AI Self-Service IVR - Model Capture.json
#
# Every resource name (both Lambdas, the IAM role, the DynamoDB table and both
# flows) can carry a common suffix, so several deployments can live side by side
# in one account (prompted for, or preset with NAME_SUFFIX).
#
# Both instance ARNs are verified against their expected alias before anything
# is deployed. The script also asks for a Lex V2 (Conversational AI) bot ARN and
# an Amazon Q in Connect AI agent ARN, checks that both exist, and rewrites the
# imported flows so every ARN points at the resources in the target instance.
#
# Amazon Connect can only invoke a Lambda in its own region, so each function is
# deployed into the region of the instance it serves. Both functions share ONE
# DynamoDB table and address it through an explicit region, so the setup still
# works when the two instances live in different regions.
#
set -euo pipefail

#-------------------------------------------------------------------------------
# Defaults
#-------------------------------------------------------------------------------
DEFAULT_SAVE_FN="ConnectSaveCustomerModel"
DEFAULT_GET_FN="ConnectGetCustomerModel"
DEFAULT_TABLE="ConnectCustomerModel"
DEFAULT_ROLE="ConnectCustomerModelLambdaRole"
PY_RUNTIME="python3.12"

# Required instance aliases. Overridable so the same script can drive other
# environments: EXPECTED_ALIAS_1=... EXPECTED_ALIAS_2=... ./deploy_connect_lambdas.sh
EXPECTED_ALIAS_1="${EXPECTED_ALIAS_1:-Amazon Connect Customer Basic}"
EXPECTED_ALIAS_2="${EXPECTED_ALIAS_2:-Amazon Connect Customer}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FLOW_FILE_1="$SCRIPT_DIR/Customer Inbound - AI IVR and Agent Transfer.json"
FLOW_FILE_2="$SCRIPT_DIR/AI Self-Service IVR - Model Capture.json"

# Appended to every resource name (Lambdas, IAM role, DynamoDB table, both
# flows). Preset it to skip the prompt:
# NAME_SUFFIX="TP" ./deploy_connect_lambdas.sh
NAME_SUFFIX="${NAME_SUFFIX-}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

log()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m  %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
die()  { printf '\033[1;31m[FAIL]\033[0m  %s\n' "$*" >&2; exit 1; }

ask() { # ask <prompt> <default> -> echoes answer
  local prompt="$1" default="$2" answer
  if [[ -n "$default" ]]; then
    read -r -p "$(printf '%s [%s]: ' "$prompt" "$default")" answer
  else
    read -r -p "$(printf '%s: ' "$prompt")" answer
  fi
  printf '%s' "${answer:-$default}"
}

ask_required() { # ask_required <prompt> -> echoes a non-empty answer
  local prompt="$1" answer=""
  while [[ -z "$answer" ]]; do
    read -r -p "$prompt" answer
    [[ -n "$answer" ]] || warn "A value is required."
  done
  printf '%s' "$answer"
}

# Connect instance aliases cannot contain spaces, so "Amazon Connect Customer
# Basic" may appear as AmazonConnectCustomerBasic, amazon-connect-customer-basic
# and so on. Compare on alphanumerics only, but still require an exact match so
# that "Amazon Connect Customer Basic" is never accepted where plain
# "Amazon Connect Customer" is expected.
norm_alias() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]'; }

# One suffix has to be legal for Lambda function names, IAM role names, DynamoDB
# table names and flow names at the same time, so everything outside
# [A-Za-z0-9] collapses to "_" and the result is always joined with "_".
# "TP", "_TP", "- TP" and "tp/2" therefore become _TP, _TP, _TP and _tp_2.
norm_suffix() { # norm_suffix <raw> -> echoes "" or "_<core>"
  local core
  core="$(sed -E 's/[^A-Za-z0-9]+/_/g; s/^_+//; s/_+$//' <<<"$1")"
  if [[ -n "$core" ]]; then
    printf '_%s' "$core"
  fi
  return 0
}

# Reads and validates one Connect instance ARN. Exports INSTANCE_ARN,
# INSTANCE_REGION, INSTANCE_ACCOUNT, INSTANCE_ID and INSTANCE_ALIAS.
read_instance_arn() { # read_instance_arn <ordinal> <expected-alias>
  local ordinal="$1" expected="$2" arn alias

  echo
  log "Connect instance #${ordinal} must be the instance whose alias is \"${expected}\"."
  arn="$(ask_required "$(printf 'Instance #%s ARN (arn:aws:connect:<region>:<acct>:instance/<id>): ' "$ordinal")")"

  [[ "$arn" =~ ^arn:aws[a-z-]*:connect:[a-z0-9-]+:[0-9]{12}:instance/[0-9a-f-]{36}$ ]] \
    || die "\"$arn\" is not a Connect instance ARN. Expected arn:aws:connect:<region>:<account>:instance/<uuid>."

  INSTANCE_ARN="$arn"
  INSTANCE_REGION="$(cut -d: -f4 <<<"$arn")"
  INSTANCE_ACCOUNT="$(cut -d: -f5 <<<"$arn")"
  INSTANCE_ID="${arn##*/}"

  log "Verifying instance $INSTANCE_ID in $INSTANCE_REGION ..."
  alias="$(aws connect describe-instance \
      --region "$INSTANCE_REGION" --instance-id "$INSTANCE_ID" \
      --query 'Instance.InstanceAlias' --output text 2>/dev/null)" \
    || die "Instance $INSTANCE_ID does not exist in $INSTANCE_REGION, or your credentials cannot describe it."
  [[ -n "$alias" && "$alias" != "None" ]] \
    || die "Instance $INSTANCE_ID has no alias, so it cannot be confirmed as \"$expected\"."

  if [[ "$(norm_alias "$alias")" != "$(norm_alias "$expected")" ]]; then
    die "$(printf 'Instance #%s is "%s" but "%s" is required for this step. Re-run with the correct instance ARN.' \
        "$ordinal" "$alias" "$expected")"
  fi

  INSTANCE_ALIAS="$alias"
  ok "Instance #${ordinal} confirmed: $alias ($INSTANCE_ID, $INSTANCE_REGION)."
}

# Reads and validates the Lex V2 bot ARN, then resolves an alias ARN to use in
# the flow. Exports LEX_BOT_ARN, LEX_BOT_ID, LEX_REGION, LEX_BOT_NAME,
# LEX_ALIAS_ARN and LEX_ALIAS_NAME.
read_lex_bot_arn() { # read_lex_bot_arn <expected-region>
  local expected_region="$1" arn alias_line

  echo
  log "Conversational AI (Amazon Lex V2) bot used by the IVR flow."
  arn="$(ask_required 'Conversational AI bot ARN (arn:aws:lex:<region>:<acct>:bot/<botId>): ')"

  [[ "$arn" =~ ^arn:aws[a-z-]*:lex:[a-z0-9-]+:[0-9]{12}:bot/[A-Z0-9]+$ ]] \
    || die "\"$arn\" is not a Lex V2 bot ARN. Expected arn:aws:lex:us-west-2:991727053196:bot/QIHKIB2VL1."

  LEX_BOT_ARN="$arn"
  local partition account
  partition="$(cut -d: -f2 <<<"$arn")"
  account="$(cut -d: -f5 <<<"$arn")"
  LEX_REGION="$(cut -d: -f4 <<<"$arn")"
  LEX_BOT_ID="${arn##*/}"

  log "Verifying Lex bot $LEX_BOT_ID in $LEX_REGION ..."
  LEX_BOT_NAME="$(aws lexv2-models describe-bot \
      --region "$LEX_REGION" --bot-id "$LEX_BOT_ID" \
      --query 'botName' --output text 2>/dev/null)" \
    || die "Lex bot $LEX_BOT_ID does not exist in $LEX_REGION, or your credentials cannot describe it."

  [[ "$LEX_REGION" == "$expected_region" ]] \
    || die "The Lex bot is in $LEX_REGION but the Connect instance is in $expected_region. Amazon Connect can only use a Lex V2 bot from its own region."

  # The flow references a bot ALIAS, not the bot itself. Prefer the alias the
  # exported flow used, otherwise take the first available one.
  alias_line="$(aws lexv2-models list-bot-aliases \
      --region "$LEX_REGION" --bot-id "$LEX_BOT_ID" \
      --query "botAliasSummaries[?botAliasStatus=='Available'].[botAliasName,botAliasId]" \
      --output text 2>/dev/null | sort)" \
    || die "Could not list aliases for Lex bot $LEX_BOT_ID."
  [[ -n "$alias_line" ]] \
    || die "Lex bot $LEX_BOT_NAME ($LEX_BOT_ID) has no available alias. Build and publish an alias first."

  local preferred
  preferred="$(grep -i -m1 $'^TestBotAlias\t' <<<"$alias_line" || true)"
  [[ -n "$preferred" ]] || preferred="$(head -n1 <<<"$alias_line")"
  LEX_ALIAS_NAME="$(cut -f1 <<<"$preferred")"
  LEX_ALIAS_ARN="arn:${partition}:lex:${LEX_REGION}:${account}:bot-alias/${LEX_BOT_ID}/$(cut -f2 <<<"$preferred")"
  ok "Lex bot confirmed: $LEX_BOT_NAME, alias $LEX_ALIAS_NAME."
}

# Reads and validates the Q in Connect AI agent ARN. Exports AI_AGENT_ARN,
# AI_AGENT_NAME, ASSISTANT_ID, ASSISTANT_ARN.
read_ai_agent_arn() { # read_ai_agent_arn <expected-region>
  local expected_region="$1" arn region resource agent_id

  echo
  log "Amazon Q in Connect AI agent used by the IVR flow."
  arn="$(ask_required 'AI Agent ARN (arn:aws:wisdom:<region>:<acct>:ai-agent/<assistantId>/<agentId>[:version]): ')"

  if [[ ! "$arn" =~ ^arn:aws[a-z-]*:wisdom:[a-z0-9-]+:[0-9]{12}:ai-agent/[0-9a-f-]{36}/[0-9a-f-]{36}(:([0-9]+|\$[A-Z]+))?$ ]]; then
    die "\"$arn\" is not an AI agent ARN. Expected arn:aws:wisdom:us-west-2:991727053196:ai-agent/14fe4db3-cca0-4c91-b484-ee7dc6a0e9aa/a0c8d2a9-1d13-4d46-9cc7-6418eac7365e:\$SAVED."
  fi

  AI_AGENT_ARN="$arn"
  region="$(cut -d: -f4 <<<"$arn")"
  resource="${arn#*:ai-agent/}"     # <assistantId>/<agentId>[:version]
  ASSISTANT_ID="${resource%%/*}"
  agent_id="${resource#*/}"
  agent_id="${agent_id%%:*}"        # drop the :$SAVED / :$LATEST / :N qualifier
  ASSISTANT_ARN="arn:$(cut -d: -f2 <<<"$arn"):wisdom:${region}:$(cut -d: -f5 <<<"$arn"):assistant/${ASSISTANT_ID}"

  log "Verifying AI agent $agent_id in $region ..."
  AI_AGENT_NAME="$(aws qconnect get-ai-agent \
      --region "$region" --assistant-id "$ASSISTANT_ID" --ai-agent-id "$agent_id" \
      --query 'aiAgent.name' --output text 2>/dev/null)" \
    || die "AI agent $agent_id was not found under assistant $ASSISTANT_ID in $region. Check the ARN and your credentials."

  [[ "$region" == "$expected_region" ]] \
    || die "The AI agent is in $region but the Connect instance is in $expected_region. Both must be in the same region."

  ok "AI agent confirmed: $AI_AGENT_NAME."
}

#-------------------------------------------------------------------------------
# Pre-flight
#-------------------------------------------------------------------------------
command -v aws >/dev/null 2>&1 || die "aws CLI not found. Install AWS CLI v2 first."
command -v zip >/dev/null 2>&1 || die "zip not found. Install zip first."
command -v python3 >/dev/null 2>&1 || die "python3 not found. It is required to rewrite the contact flow exports."
[[ -f "$FLOW_FILE_1" ]] || die "Flow export not found: $FLOW_FILE_1"
[[ -f "$FLOW_FILE_2" ]] || die "Flow export not found: $FLOW_FILE_2"

echo
echo "=============================================================="
echo " Amazon Connect + Lambda + DynamoDB + contact flow deployment"
echo "=============================================================="
echo
echo " Instance #1 must be \"$EXPECTED_ALIAS_1\""
echo "   -> Lambda $DEFAULT_GET_FN  (reads back the latest ModelNumber)"
echo "   -> Flow   $(basename "$FLOW_FILE_1")"
echo
echo " Instance #2 must be \"$EXPECTED_ALIAS_2\""
echo "   -> Lambda $DEFAULT_SAVE_FN (stores CustomerNumber + ModelNumber)"
echo "   -> Flow   $(basename "$FLOW_FILE_2")"
echo
echo " You will also be asked for a Conversational AI (Lex V2) bot ARN and an"
echo " Amazon Q in Connect AI agent ARN. Every input is verified before any"
echo " resource is created; the script exits on the first mismatch."
echo

#-------------------------------------------------------------------------------
# Interactive input - instances, bot and AI agent are all validated up front
#-------------------------------------------------------------------------------
read_instance_arn 1 "$EXPECTED_ALIAS_1"
GET_INSTANCE_ARN="$INSTANCE_ARN"
GET_REGION="$INSTANCE_REGION"
GET_ACCOUNT="$INSTANCE_ACCOUNT"
GET_INSTANCE_ID="$INSTANCE_ID"
GET_INSTANCE_ALIAS="$INSTANCE_ALIAS"

read_instance_arn 2 "$EXPECTED_ALIAS_2"
SAVE_INSTANCE_ARN="$INSTANCE_ARN"
SAVE_REGION="$INSTANCE_REGION"
SAVE_ACCOUNT="$INSTANCE_ACCOUNT"
SAVE_INSTANCE_ID="$INSTANCE_ID"
SAVE_INSTANCE_ALIAS="$INSTANCE_ALIAS"

[[ "$SAVE_ACCOUNT" == "$GET_ACCOUNT" ]] \
  || die "The two instances are in different accounts ($GET_ACCOUNT / $SAVE_ACCOUNT). This script deploys into a single account."
ACCOUNT_ID="$SAVE_ACCOUNT"

[[ "$SAVE_INSTANCE_ID" != "$GET_INSTANCE_ID" ]] \
  || die "Both ARNs point at the same instance. \"$EXPECTED_ALIAS_1\" and \"$EXPECTED_ALIAS_2\" must be two different instances."

# The bot and the AI agent are consumed by the flow on instance #2.
read_lex_bot_arn  "$SAVE_REGION"
read_ai_agent_arn "$SAVE_REGION"

# The suffix comes first so every name prompt below can offer the final name as
# its default. It keeps several deployments apart inside one account/instance.
echo
NAME_SUFFIX="$(norm_suffix "$(ask 'Suffix for every resource name, e.g. TP (blank for none)' "$NAME_SUFFIX")")"
[[ -z "$NAME_SUFFIX" ]] || log "All resource names will end in \"$NAME_SUFFIX\"."

flow_name_in_file() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["Metadata"]["name"])' "$1"; }

echo
SAVE_FN="$(ask 'Save Lambda function name'  "${DEFAULT_SAVE_FN}${NAME_SUFFIX}")"
GET_FN="$(ask  'Get  Lambda function name'  "${DEFAULT_GET_FN}${NAME_SUFFIX}")"
TABLE_NAME="$(ask 'DynamoDB table name'     "${DEFAULT_TABLE}${NAME_SUFFIX}")"
ROLE_NAME="$(ask  'IAM execution role name' "${DEFAULT_ROLE}${NAME_SUFFIX}")"
FLOW_NAME_1="$(ask 'Flow name on instance #1' "$(flow_name_in_file "$FLOW_FILE_1")${NAME_SUFFIX}")"
FLOW_NAME_2="$(ask 'Flow name on instance #2' "$(flow_name_in_file "$FLOW_FILE_2")${NAME_SUFFIX}")"

# One table shared by both functions. Defaults to the save instance's region.
if [[ "$SAVE_REGION" == "$GET_REGION" ]]; then
  TABLE_REGION="$SAVE_REGION"
else
  warn "The two instances are in different regions: $SAVE_REGION vs $GET_REGION."
  warn "Each Lambda must sit in its own instance's region, but they will share one table."
  TABLE_REGION="$(ask 'Region to host the shared DynamoDB table' "$SAVE_REGION")"
fi

CALLER_ACCOUNT="$(aws sts get-caller-identity --query Account --output text)" \
  || die "Unable to call STS. Check your AWS credentials."
[[ "$CALLER_ACCOUNT" == "$ACCOUNT_ID" ]] \
  || die "Credentials belong to account $CALLER_ACCOUNT but the instance ARNs are in $ACCOUNT_ID."

TABLE_ARN="arn:aws:dynamodb:${TABLE_REGION}:${ACCOUNT_ID}:table/${TABLE_NAME}"

cat <<EOF

--------------------------------------------------------------
 Account                 : $ACCOUNT_ID
 Instance #1             : $GET_INSTANCE_ALIAS  ($GET_INSTANCE_ID, $GET_REGION)
   Lambda                : $GET_FN
   Flow                  : $FLOW_NAME_1
 Instance #2             : $SAVE_INSTANCE_ALIAS  ($SAVE_INSTANCE_ID, $SAVE_REGION)
   Lambda                : $SAVE_FN
   Flow                  : $FLOW_NAME_2
   Lex V2 bot            : $LEX_BOT_NAME / $LEX_ALIAS_NAME
   Q in Connect AI agent : $AI_AGENT_NAME
 DynamoDB table (shared) : $TABLE_NAME  ($TABLE_REGION)
 IAM role                : $ROLE_NAME
 Runtime                 : $PY_RUNTIME
--------------------------------------------------------------
EOF

CONFIRM="$(ask 'Proceed?' 'y')"
[[ "$CONFIRM" =~ ^[Yy] ]] || die "Aborted by user."

#-------------------------------------------------------------------------------
# 1. DynamoDB table
#    Partition key: CustomerNumber (S)   Sort key: CreatedAt (S, ISO-8601 UTC)
#    ISO-8601 sorts lexicographically, so "latest" == last item in key order.
#-------------------------------------------------------------------------------
log "Checking DynamoDB table $TABLE_NAME in $TABLE_REGION ..."
if aws dynamodb describe-table --region "$TABLE_REGION" --table-name "$TABLE_NAME" >/dev/null 2>&1; then
  # An earlier interrupted run may have left the table in CREATING state.
  aws dynamodb wait table-exists --region "$TABLE_REGION" --table-name "$TABLE_NAME"

  # Reusing a table whose key schema differs would break the "latest record"
  # query, so verify it rather than silently adopting the wrong table.
  EXISTING_HASH="$(aws dynamodb describe-table \
    --region "$TABLE_REGION" --table-name "$TABLE_NAME" \
    --query "Table.KeySchema[?KeyType=='HASH']|[0].AttributeName" --output text)"
  EXISTING_RANGE="$(aws dynamodb describe-table \
    --region "$TABLE_REGION" --table-name "$TABLE_NAME" \
    --query "Table.KeySchema[?KeyType=='RANGE']|[0].AttributeName" --output text)"

  if [[ "$EXISTING_HASH" != "CustomerNumber" || "$EXISTING_RANGE" != "CreatedAt" ]]; then
    die "Table $TABLE_NAME already exists in $TABLE_REGION with an incompatible key schema (HASH=$EXISTING_HASH, RANGE=$EXISTING_RANGE). Expected HASH=CustomerNumber, RANGE=CreatedAt. Pick a different table name or remove the existing table."
  fi
  ok "Table already exists with a compatible key schema, reusing it."
else
  log "Creating table $TABLE_NAME (on-demand billing) ..."
  aws dynamodb create-table \
    --region "$TABLE_REGION" \
    --table-name "$TABLE_NAME" \
    --attribute-definitions \
        AttributeName=CustomerNumber,AttributeType=S \
        AttributeName=CreatedAt,AttributeType=S \
    --key-schema \
        AttributeName=CustomerNumber,KeyType=HASH \
        AttributeName=CreatedAt,KeyType=RANGE \
    --billing-mode PAY_PER_REQUEST \
    --no-cli-pager >/dev/null
  aws dynamodb wait table-exists --region "$TABLE_REGION" --table-name "$TABLE_NAME"
  ok "Table created."
fi

#-------------------------------------------------------------------------------
# 2. IAM execution role (global, shared by both functions)
#-------------------------------------------------------------------------------
TRUST_DOC="$WORKDIR/trust.json"
cat >"$TRUST_DOC" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

POLICY_DOC="$WORKDIR/policy.json"
cat >"$POLICY_DOC" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TableData",
      "Effect": "Allow",
      "Action": [
        "dynamodb:PutItem",
        "dynamodb:GetItem",
        "dynamodb:Query",
        "dynamodb:DescribeTable"
      ],
      "Resource": [
        "${TABLE_ARN}",
        "${TABLE_ARN}/index/*"
      ]
    },
    {
      "Sid": "AutoCreateTable",
      "Effect": "Allow",
      "Action": [
        "dynamodb:CreateTable",
        "dynamodb:ListTables"
      ],
      "Resource": "*"
    }
  ]
}
EOF

log "Checking IAM role $ROLE_NAME ..."
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  # Re-apply the trust policy so a pre-existing role that Lambda cannot assume
  # gets corrected instead of failing later at create-function time.
  aws iam update-assume-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-document "file://$TRUST_DOC" >/dev/null \
    || die "Could not update the trust policy on role $ROLE_NAME. Check your IAM permissions."
  ok "Role already exists, trust policy re-applied."
  ROLE_CREATED=false
else
  # A busy account can be at the RolesPerAccount quota, which fails here with an
  # error that says nothing about how to get moving again.
  if ! CREATE_ROLE_ERR="$(aws iam create-role \
      --role-name "$ROLE_NAME" \
      --assume-role-policy-document "file://$TRUST_DOC" \
      --description "Execution role for Amazon Connect customer/model Lambda functions" \
      --no-cli-pager 2>&1 >/dev/null)"; then
    if grep -qi "RolesPerAccount\|LimitExceeded" <<<"$CREATE_ROLE_ERR"; then
      die "$(printf 'This account is at the IAM roles quota, so role %s cannot be created.\n         Re-run and answer the "IAM execution role name" prompt with an existing\n         Lambda execution role, or delete unused roles / request a quota increase.\n         AWS said: %s' "$ROLE_NAME" "$CREATE_ROLE_ERR")"
    fi
    die "Could not create role $ROLE_NAME: $CREATE_ROLE_ERR"
  fi
  ok "Role created."
  ROLE_CREATED=true
fi

aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole >/dev/null \
  || die "Could not attach AWSLambdaBasicExecutionRole to $ROLE_NAME."
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "CustomerModelTableAccess" \
  --policy-document "file://$POLICY_DOC" >/dev/null \
  || die "Could not put the CustomerModelTableAccess policy on $ROLE_NAME."
ok "Policies attached."

ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)"

if [[ "$ROLE_CREATED" == true ]]; then
  log "Waiting 15s for IAM role propagation ..."
  sleep 15
fi

#-------------------------------------------------------------------------------
# 3. Lambda source code
#-------------------------------------------------------------------------------
SRC_SAVE="$WORKDIR/save"
SRC_GET="$WORKDIR/get"
mkdir -p "$SRC_SAVE" "$SRC_GET"

cat >"$SRC_SAVE/lambda_function.py" <<'PYCODE'
"""Amazon Connect -> DynamoDB: store CustomerNumber + ModelNumber.

Creates the DynamoDB table on the fly if it does not exist yet.
Returns a flat string map, which is what Amazon Connect contact flows expect.
"""
import os
import json
import logging
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

TABLE_NAME = os.environ["TABLE_NAME"]
# The table may live in a different region than this function when the two
# Connect instances are in different regions, so address it explicitly.
TABLE_REGION = os.environ.get("TABLE_REGION") or os.environ["AWS_REGION"]

_ddb_client = boto3.client("dynamodb", region_name=TABLE_REGION)
_ddb_resource = boto3.resource("dynamodb", region_name=TABLE_REGION)


def ensure_table():
    """Create the table if missing. Safe to call on every invocation."""
    try:
        _ddb_client.describe_table(TableName=TABLE_NAME)
        return
    except ClientError as err:
        if err.response["Error"]["Code"] != "ResourceNotFoundException":
            raise

    LOG.info("Table %s not found in %s, creating it", TABLE_NAME, TABLE_REGION)
    try:
        _ddb_client.create_table(
            TableName=TABLE_NAME,
            AttributeDefinitions=[
                {"AttributeName": "CustomerNumber", "AttributeType": "S"},
                {"AttributeName": "CreatedAt", "AttributeType": "S"},
            ],
            KeySchema=[
                {"AttributeName": "CustomerNumber", "KeyType": "HASH"},
                {"AttributeName": "CreatedAt", "KeyType": "RANGE"},
            ],
            BillingMode="PAY_PER_REQUEST",
        )
    except ClientError as err:
        # Another concurrent invocation may have won the race.
        if err.response["Error"]["Code"] not in (
            "ResourceInUseException",
            "TableAlreadyExistsException",
        ):
            raise
    _ddb_client.get_waiter("table_exists").wait(
        TableName=TABLE_NAME, WaiterConfig={"Delay": 2, "MaxAttempts": 60}
    )
    LOG.info("Table %s is active", TABLE_NAME)


def normalize_number(raw):
    """Keep digits and a leading + so lookups match regardless of formatting."""
    if not raw:
        return ""
    raw = str(raw).strip()
    plus = raw.startswith("+")
    digits = "".join(ch for ch in raw if ch.isdigit())
    return ("+" if plus else "") + digits


def pick(params, *names):
    lowered = {str(k).lower(): v for k, v in params.items()}
    for name in names:
        value = lowered.get(name.lower())
        if value not in (None, ""):
            return str(value)
    return ""


def extract(event):
    """Read parameters from a Connect event, a direct test event, or API GW."""
    details = event.get("Details") or {}
    params = dict(details.get("Parameters") or {})

    contact_data = details.get("ContactData") or {}
    attributes = contact_data.get("Attributes") or {}
    for key, value in attributes.items():
        params.setdefault(key, value)

    # Fall back to the caller's ANI when CustomerNumber was not passed in.
    endpoint = (contact_data.get("CustomerEndpoint") or {}).get("Address")
    if endpoint:
        params.setdefault("CustomerNumber", endpoint)

    if not params:
        if isinstance(event.get("body"), str):
            try:
                params = json.loads(event["body"])
            except (ValueError, TypeError):
                params = {}
        else:
            params = {k: v for k, v in event.items() if isinstance(v, (str, int, float))}

    customer_number = pick(params, "CustomerNumber", "customerNumber", "PhoneNumber")
    model_number = pick(params, "ModelNumber", "modelNumber", "Model")
    contact_id = contact_data.get("ContactId", "")
    return customer_number, model_number, contact_id


def lambda_handler(event, context):
    LOG.info("Event: %s", json.dumps(event, default=str))

    customer_number, model_number, contact_id = extract(event)

    if not customer_number or not model_number:
        return {
            "Status": "FAILED",
            "ErrorMessage": "CustomerNumber and ModelNumber are both required.",
        }

    ensure_table()

    created_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    item = {
        "CustomerNumber": normalize_number(customer_number),
        "CreatedAt": created_at,
        "ModelNumber": model_number.strip(),
        "RawCustomerNumber": str(customer_number).strip(),
    }
    if contact_id:
        item["ContactId"] = contact_id

    _ddb_resource.Table(TABLE_NAME).put_item(Item=item)
    LOG.info("Stored %s", json.dumps(item))

    return {
        "Status": "SUCCESS",
        "CustomerNumber": item["CustomerNumber"],
        "ModelNumber": item["ModelNumber"],
        "CreatedAt": created_at,
    }
PYCODE

cat >"$SRC_GET/lambda_function.py" <<'PYCODE'
"""Amazon Connect -> DynamoDB: return the newest ModelNumber for a customer.

Queries the table by CustomerNumber in descending sort-key order and returns
the first hit, i.e. the most recently inserted record.
"""
import os
import json
import logging

import boto3
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

TABLE_NAME = os.environ["TABLE_NAME"]
# The writer function may live in another region; the table is shared, so
# address it explicitly instead of relying on this function's own region.
TABLE_REGION = os.environ.get("TABLE_REGION") or os.environ["AWS_REGION"]

_ddb_resource = boto3.resource("dynamodb", region_name=TABLE_REGION)


def normalize_number(raw):
    if not raw:
        return ""
    raw = str(raw).strip()
    plus = raw.startswith("+")
    digits = "".join(ch for ch in raw if ch.isdigit())
    return ("+" if plus else "") + digits


def candidates(raw):
    """Try the normalized form first, then a couple of common variants."""
    normalized = normalize_number(raw)
    out = [normalized]
    if normalized.startswith("+"):
        out.append(normalized[1:])
    else:
        out.append("+" + normalized)
    out.append(str(raw).strip())
    seen, unique = set(), []
    for value in out:
        if value and value not in seen:
            seen.add(value)
            unique.append(value)
    return unique


def extract(event):
    details = event.get("Details") or {}
    params = dict(details.get("Parameters") or {})

    contact_data = details.get("ContactData") or {}
    for key, value in (contact_data.get("Attributes") or {}).items():
        params.setdefault(key, value)
    endpoint = (contact_data.get("CustomerEndpoint") or {}).get("Address")
    if endpoint:
        params.setdefault("CustomerNumber", endpoint)

    if not params:
        if isinstance(event.get("body"), str):
            try:
                params = json.loads(event["body"])
            except (ValueError, TypeError):
                params = {}
        else:
            params = {k: v for k, v in event.items() if isinstance(v, (str, int, float))}

    lowered = {str(k).lower(): v for k, v in params.items()}
    for name in ("customernumber", "phonenumber", "customerphonenumber"):
        if lowered.get(name):
            return str(lowered[name])
    return ""


def lambda_handler(event, context):
    LOG.info("Event: %s", json.dumps(event, default=str))

    customer_number = extract(event)
    if not customer_number:
        return {
            "Status": "FAILED",
            "Found": "false",
            "ErrorMessage": "CustomerNumber is required.",
        }

    table = _ddb_resource.Table(TABLE_NAME)

    for key in candidates(customer_number):
        try:
            response = table.query(
                KeyConditionExpression=Key("CustomerNumber").eq(key),
                ScanIndexForward=False,  # newest CreatedAt first
                Limit=1,
            )
        except ClientError as err:
            if err.response["Error"]["Code"] == "ResourceNotFoundException":
                return {
                    "Status": "SUCCESS",
                    "Found": "false",
                    "ModelNumber": "",
                    "CustomerNumber": normalize_number(customer_number),
                    "Message": "Table does not exist yet, no records stored.",
                }
            raise

        items = response.get("Items") or []
        if items:
            item = items[0]
            result = {
                "Status": "SUCCESS",
                "Found": "true",
                "CustomerNumber": key,
                "ModelNumber": item.get("ModelNumber", ""),
                "CreatedAt": item.get("CreatedAt", ""),
            }
            LOG.info("Result: %s", json.dumps(result))
            return result

    return {
        "Status": "SUCCESS",
        "Found": "false",
        "CustomerNumber": normalize_number(customer_number),
        "ModelNumber": "",
        "Message": "No record found for this customer number.",
    }
PYCODE

(cd "$SRC_SAVE" && zip -q -r "$WORKDIR/save.zip" .)
(cd "$SRC_GET"  && zip -q -r "$WORKDIR/get.zip"  .)
ok "Deployment packages built."

#-------------------------------------------------------------------------------
# 4. Deploy / update the functions, then wire each one to its own instance
#-------------------------------------------------------------------------------
deploy_function() { # deploy_function <name> <region> <zip> <description>
  local name="$1" region="$2" zip_path="$3" description="$4"

  if aws lambda get-function --region "$region" --function-name "$name" >/dev/null 2>&1; then
    # A zip upload cannot update a container-image function, so stop early with
    # a clear message instead of a confusing API error.
    local package_type
    package_type="$(aws lambda get-function --region "$region" --function-name "$name" \
      --query 'Configuration.PackageType' --output text)"
    [[ "$package_type" == "Zip" ]] \
      || die "Function $name in $region already exists with PackageType=$package_type. This script deploys zip packages. Pick a different function name."

    # An earlier interrupted run may have left the function in Pending state,
    # which would make update-function-code fail.
    aws lambda wait function-active-v2 --region "$region" --function-name "$name"

    log "Updating existing function $name in $region ..."
    aws lambda update-function-code \
      --region "$region" --function-name "$name" \
      --zip-file "fileb://$zip_path" --no-cli-pager >/dev/null
    aws lambda wait function-updated --region "$region" --function-name "$name"
    aws lambda update-function-configuration \
      --region "$region" --function-name "$name" \
      --role "$ROLE_ARN" --handler lambda_function.lambda_handler \
      --runtime "$PY_RUNTIME" --timeout 30 --memory-size 256 \
      --environment "Variables={TABLE_NAME=$TABLE_NAME,TABLE_REGION=$TABLE_REGION}" \
      --description "$description" --no-cli-pager >/dev/null
    aws lambda wait function-updated --region "$region" --function-name "$name"
  else
    log "Creating function $name in $region ..."
    aws lambda create-function \
      --region "$region" --function-name "$name" \
      --runtime "$PY_RUNTIME" --role "$ROLE_ARN" \
      --handler lambda_function.lambda_handler \
      --zip-file "fileb://$zip_path" \
      --timeout 30 --memory-size 256 \
      --environment "Variables={TABLE_NAME=$TABLE_NAME,TABLE_REGION=$TABLE_REGION}" \
      --description "$description" --no-cli-pager >/dev/null
    aws lambda wait function-active-v2 --region "$region" --function-name "$name"
  fi
  ok "$name deployed in $region."
}

allow_connect() { # allow_connect <function-name> <region> <instance-arn>
  local name="$1" region="$2" instance_arn="$3"
  local sid="AllowAmazonConnectInvoke"
  aws lambda remove-permission \
    --region "$region" --function-name "$name" --statement-id "$sid" >/dev/null 2>&1 || true
  aws lambda add-permission \
    --region "$region" --function-name "$name" \
    --statement-id "$sid" \
    --action lambda:InvokeFunction \
    --principal connect.amazonaws.com \
    --source-account "$ACCOUNT_ID" \
    --source-arn "$instance_arn" --no-cli-pager >/dev/null
  ok "Resource policy on $name scoped to ${instance_arn##*/}."
}

associate_connect() { # associate_connect <function-name> <region> <instance-id>
  local name="$1" region="$2" instance_id="$3"
  local arn="arn:aws:lambda:${region}:${ACCOUNT_ID}:function:${name}"
  local existing output

  # Check the current associations first. This avoids depending on the exact
  # error string when the association is already in place.
  if existing="$(aws connect list-lambda-functions \
        --region "$region" --instance-id "$instance_id" \
        --query 'LambdaFunctions[]' --output text 2>/dev/null)"; then
    if tr '\t' '\n' <<<"$existing" | grep -qxF -- "$arn"; then
      ok "$name already associated with instance $instance_id, nothing to do."
      return 0
    fi
  fi

  if output="$(aws connect associate-lambda-function \
        --region "$region" \
        --instance-id "$instance_id" \
        --function-arn "$arn" 2>&1)"; then
    ok "Associated $name with instance $instance_id."
  elif grep -qi "DuplicateResource" <<<"$output"; then
    ok "$name already associated with instance $instance_id."
  else
    warn "Could not associate $name automatically: $output"
    warn "Add it manually: Connect console -> Flows -> AWS Lambda -> $arn"
  fi
}

deploy_function "$SAVE_FN" "$SAVE_REGION" "$WORKDIR/save.zip" \
  "Stores CustomerNumber and ModelNumber from Amazon Connect into DynamoDB table $TABLE_NAME"
deploy_function "$GET_FN" "$GET_REGION" "$WORKDIR/get.zip" \
  "Returns the latest ModelNumber for a CustomerNumber from DynamoDB table $TABLE_NAME"

allow_connect "$SAVE_FN" "$SAVE_REGION" "$SAVE_INSTANCE_ARN"
allow_connect "$GET_FN"  "$GET_REGION"  "$GET_INSTANCE_ARN"

associate_connect "$SAVE_FN" "$SAVE_REGION" "$SAVE_INSTANCE_ID"
associate_connect "$GET_FN"  "$GET_REGION"  "$GET_INSTANCE_ID"

#-------------------------------------------------------------------------------
# 5. Contact flows
#    The exports were taken from another instance, so every embedded ARN has to
#    be repointed before Connect will accept them.
#-------------------------------------------------------------------------------
PREP="$WORKDIR/prepare_flow.py"
cat >"$PREP" <<'PYCODE'
#!/usr/bin/env python3
"""Rewrite an Amazon Connect flow export so it can be imported elsewhere.

Repoints Lambda / Lex V2 / Q in Connect ARNs at the resources this deployment
created, remaps contact-flow and queue references by display name, and drops
event hooks whose flow does not exist in the target instance.
"""
import argparse
import json
import re
import sys

LAMBDA_RE = r'arn:aws[a-z-]*:lambda:[a-z0-9-]+:[0-9]{12}:function:[A-Za-z0-9_-]+'
LEX_ALIAS_RE = r'arn:aws[a-z-]*:lex:[a-z0-9-]+:[0-9]{12}:bot-alias/[A-Z0-9]+/[A-Z0-9]+'
AI_AGENT_RE = (r'arn:aws[a-z-]*:wisdom:[a-z0-9-]+:[0-9]{12}:ai-agent/[0-9a-f-]{36}'
               r'/[0-9a-f-]{36}(?::(?:\$[A-Z]+|[0-9]+))?')
ASSISTANT_RE = r'arn:aws[a-z-]*:wisdom:[a-z0-9-]+:[0-9]{12}:assistant/[0-9a-f-]{36}'
INSTANCE_RES_RE = r'arn:aws[a-z-]*:connect:[a-z0-9-]+:[0-9]{12}:instance/[0-9a-f-]{36}/[^"]+'

# An event hook always takes a flow of one specific type, so when the exported
# name is missing in the target instance the type-matching default is a safe
# substitute. Instances differ here: the same flow is called "Default agent
# whisper" in one instance and "Default agent whisper - Transfer to Agent" in
# another. DefaultAgentUI is deliberately absent - it points at a regular
# CONTACT_FLOW that only exists if someone built it.
HOOK_FLOW_TYPES = {
    'AgentWhisper': 'AGENT_WHISPER',
    'CustomerWhisper': 'CUSTOMER_WHISPER',
    'OutboundWhisper': 'OUTBOUND_WHISPER',
    'CustomerQueue': 'CUSTOMER_QUEUE',
    'CustomerHold': 'CUSTOMER_HOLD',
    'AgentHold': 'AGENT_HOLD',
    'AgentTransfer': 'AGENT_TRANSFER',
    'QueueTransfer': 'QUEUE_TRANSFER',
}


def emit(colour, level, msg):
    sys.stderr.write('\033[1;%sm[%s]\033[0m  %s\n' % (colour, level, msg))


def info(msg):
    emit('34', 'INFO', msg)


def warn(msg):
    emit('33', 'WARN', msg)


def fail(msg):
    emit('31', 'FAIL', msg)
    sys.exit(1)


def load_entries(path):
    """The raw list produced by `aws ... --output json`."""
    if not path:
        return []
    with open(path) as handle:
        return json.load(handle) or []


def load_map(path):
    """{"Name": "Arn"} from an `aws ... --output json` list."""
    return {e['Name']: e['Arn'] for e in load_entries(path)
            if e.get('Name') and e.get('Arn')}


def arn_by_name(entries, name):
    for entry in entries:
        if name and entry.get('Name') == name:
            return entry.get('Arn')
    return None


def default_of_type(entries, flow_type):
    """The instance's flow of a given type, preferring the AWS-provided one."""
    matches = [e for e in entries if e.get('Type') == flow_type and e.get('Arn')]
    if not matches:
        return None, None
    matches.sort(key=lambda e: (not str(e.get('Name', '')).startswith('Default'),
                                str(e.get('Name', ''))))
    return matches[0]['Arn'], matches[0].get('Name')


def display_name(meta, param):
    node = (meta.get('parameters') or {}).get(param)
    return node.get('displayName') if isinstance(node, dict) else None


def replace_arns(text, pattern, replacement, label):
    if not replacement:
        return text
    for old in sorted(set(re.findall(pattern, text))):
        if old != replacement:
            info('%s: %s -> %s' % (label, old, replacement))
            text = text.replace(old, replacement)
    return text


def fix_display_names(node, args):
    """Metadata display names are cosmetic but a stale one looks like a bug."""
    if isinstance(node, dict):
        for key, value in node.items():
            if key in ('LambdaFunctionARN', 'AliasArn') and isinstance(value, dict):
                new = args.lambda_name if key == 'LambdaFunctionARN' else args.lex_alias_name
                if new and 'displayName' in value:
                    value['displayName'] = new
            elif key == 'lexV2BotName' and args.lex_bot_name:
                node[key] = args.lex_bot_name
            elif key == 'lexV2BotAliasName' and args.lex_alias_name:
                node[key] = args.lex_alias_name
            elif key == 'aiAgentName' and args.ai_agent_name:
                node[key] = args.ai_agent_name
            fix_display_names(value, args)
    elif isinstance(node, list):
        for item in node:
            fix_display_names(item, args)


def remap_instance_resources(data, flows, queue_map):
    """Returns (old_arn -> new_arn, {action id -> id to skip to})."""
    meta_actions = (data.get('Metadata') or {}).get('ActionMetadata') or {}
    arn_map, drop_next = {}, {}

    for action in data.get('Actions') or []:
        ident = action.get('Identifier')
        meta = meta_actions.get(ident) or {}
        params = action.get('Parameters') or {}

        if action.get('Type') == 'UpdateContactEventHooks':
            hooks = params.get('EventHooks') or {}
            meta_hooks = (meta.get('parameters') or {}).get('EventHooks') or {}
            for hook, old_arn in list(hooks.items()):
                if not isinstance(old_arn, str) or '/contact-flow/' not in old_arn:
                    continue
                name = (meta_hooks.get(hook) or {}).get('displayName')
                target = arn_by_name(flows, name)
                if not target:
                    target, picked = default_of_type(
                        flows, HOOK_FLOW_TYPES.get(hook, ''))
                    if target:
                        warn('Event hook %s: flow "%s" does not exist in the '
                             'target instance, using its "%s" instead.'
                             % (hook, name or old_arn, picked))
                        if isinstance(meta_hooks.get(hook), dict):
                            meta_hooks[hook]['displayName'] = picked
                        flow_meta = meta.get('contactFlow')
                        if isinstance(flow_meta, dict) and flow_meta.get('id') == old_arn:
                            flow_meta['text'] = picked
                if target:
                    arn_map[old_arn] = target
                else:
                    warn('Event hook %s points at flow "%s", which the target '
                         'instance does not have. Dropping the hook.'
                         % (hook, name or old_arn))
                    hooks.pop(hook, None)
                    meta_hooks.pop(hook, None)
            if not hooks:
                nxt = (action.get('Transitions') or {}).get('NextAction')
                if not nxt:
                    fail('Action %s lost every event hook and has no NextAction '
                         'to skip to.' % ident)
                drop_next[ident] = nxt

        elif action.get('Type') == 'UpdateContactTargetQueue':
            old_arn = params.get('QueueId')
            if not isinstance(old_arn, str) or '/queue/' not in old_arn:
                continue
            name = display_name(meta, 'QueueId')
            target = queue_map.get(name) if name else None
            if not target:
                if not queue_map:
                    fail('The target instance has no standard queue, so queue '
                         '"%s" cannot be remapped.' % (name or old_arn))
                fallback = sorted(queue_map)[0]
                target = queue_map[fallback]
                warn('Queue "%s" does not exist in the target instance, routing '
                     'to "%s" instead.' % (name or old_arn, fallback))
            arn_map[old_arn] = target

    return arn_map, drop_next


def drop_actions(data, drop_next):
    """Remove actions and point everything that referenced them further down."""
    if not drop_next:
        return

    def resolve(target):
        seen = set()
        while target in drop_next:
            if target in seen:
                fail('Circular transitions while removing unusable actions.')
            seen.add(target)
            target = drop_next[target]
        return target

    def rewire(node):
        if isinstance(node, dict):
            for key, value in node.items():
                if key == 'NextAction' and isinstance(value, str):
                    node[key] = resolve(value)
                else:
                    rewire(value)
        elif isinstance(node, list):
            for item in node:
                rewire(item)

    rewire(data.get('Actions'))
    if data.get('StartAction') in drop_next:
        data['StartAction'] = resolve(data['StartAction'])
    data['Actions'] = [a for a in data['Actions']
                       if a.get('Identifier') not in drop_next]
    meta_actions = (data.get('Metadata') or {}).get('ActionMetadata') or {}
    for ident in drop_next:
        meta_actions.pop(ident, None)
    info('Removed %d action(s) that referenced missing resources.' % len(drop_next))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--flow-file', required=True)
    parser.add_argument('--out-file', required=True)
    parser.add_argument('--instance-id', required=True)
    parser.add_argument('--name')
    parser.add_argument('--lambda-arn')
    parser.add_argument('--lambda-name')
    parser.add_argument('--lex-alias-arn')
    parser.add_argument('--lex-bot-name')
    parser.add_argument('--lex-alias-name')
    parser.add_argument('--ai-agent-arn')
    parser.add_argument('--ai-agent-name')
    parser.add_argument('--assistant-arn')
    parser.add_argument('--flow-map')
    parser.add_argument('--queue-map')
    args = parser.parse_args()

    with open(args.flow_file) as handle:
        data = json.load(handle)

    arn_map, drop_next = remap_instance_resources(
        data, load_entries(args.flow_map), load_map(args.queue_map))
    drop_actions(data, drop_next)
    fix_display_names(data, args)
    if args.name:
        data.setdefault('Metadata', {})['name'] = args.name

    text = json.dumps(data, indent=2)
    for old, new in arn_map.items():
        if old != new:
            info('Instance resource: %s -> %s' % (old, new))
            text = text.replace(old, new)
    text = replace_arns(text, LAMBDA_RE, args.lambda_arn, 'Lambda')
    text = replace_arns(text, LEX_ALIAS_RE, args.lex_alias_arn, 'Lex bot alias')
    text = replace_arns(text, AI_AGENT_RE, args.ai_agent_arn, 'AI agent')
    text = replace_arns(text, ASSISTANT_RE, args.assistant_arn, 'Q in Connect assistant')

    stale = sorted({arn for arn in re.findall(INSTANCE_RES_RE, text)
                    if 'instance/%s/' % args.instance_id not in arn})
    if stale:
        fail('These references still belong to another Connect instance:\n  '
             + '\n  '.join(stale))

    json.loads(text)  # guard against producing invalid JSON
    with open(args.out_file, 'w') as handle:
        handle.write(text)


if __name__ == '__main__':
    main()
PYCODE

flow_id_by_name() { # flow_id_by_name <flows-json> <name>
  python3 - "$1" "$2" <<'PYCODE'
import json, sys
entries = json.load(open(sys.argv[1])) or []
for entry in entries:
    if entry.get("Name") == sys.argv[2]:
        print("%s\t%s" % (entry.get("Id", ""), entry.get("Type", "")))
        break
PYCODE
}

list_flows_json() { # list_flows_json <region> <instance-id> <out-file>
  aws connect list-contact-flows \
    --region "$1" --instance-id "$2" \
    --query 'ContactFlowSummaryList[].{Name:Name,Arn:Arn,Id:Id,Type:ContactFlowType}' \
    --output json >"$3"
}

deploy_flow() { # deploy_flow <region> <instance-id> <src-file> <flow-name> <lambda-arn> <lambda-name> [--with-ai]
  local region="$1" instance_id="$2" src="$3" name="$4" lambda_arn="$5" lambda_name="$6" with_ai="${7:-no}"
  local flows="$WORKDIR/flows-${instance_id}.json"
  local queues="$WORKDIR/queues-${instance_id}.json"
  local prepared="$WORKDIR/flow-${instance_id}.json"
  local existing id type

  log "Preparing flow \"$name\" for instance $instance_id ..."
  list_flows_json "$region" "$instance_id" "$flows"
  aws connect list-queues \
    --region "$region" --instance-id "$instance_id" --queue-types STANDARD \
    --query 'QueueSummaryList[].{Name:Name,Arn:Arn}' --output json >"$queues"

  local -a prep_args=(
    --flow-file "$src" --out-file "$prepared" --name "$name"
    --instance-id "$instance_id"
    --lambda-arn "$lambda_arn" --lambda-name "$lambda_name"
    --flow-map "$flows" --queue-map "$queues"
  )
  if [[ "$with_ai" == "with-ai" ]]; then
    prep_args+=(
      --lex-alias-arn "$LEX_ALIAS_ARN" --lex-bot-name "$LEX_BOT_NAME"
      --lex-alias-name "$LEX_ALIAS_NAME"
      --ai-agent-arn "$AI_AGENT_ARN" --ai-agent-name "$AI_AGENT_NAME"
      --assistant-arn "$ASSISTANT_ARN"
    )
  fi
  python3 "$PREP" "${prep_args[@]}" \
    || die "Could not rewrite $(basename "$src") for instance $instance_id."

  existing="$(flow_id_by_name "$flows" "$name")"
  id="$(cut -f1 <<<"$existing")"
  type="$(cut -f2 <<<"$existing")"

  if [[ -n "$id" ]]; then
    [[ "$type" == "CONTACT_FLOW" ]] \
      || die "Instance $instance_id already has a flow named \"$name\" of type $type. Pick a different flow name."
    warn "Instance $instance_id already has a flow named \"$name\"."
    local overwrite
    overwrite="$(ask "Overwrite its content?" 'y')"
    [[ "$overwrite" =~ ^[Yy] ]] || die "Aborted: flow \"$name\" left untouched."
    aws connect update-contact-flow-content \
      --region "$region" --instance-id "$instance_id" \
      --contact-flow-id "$id" --content "file://$prepared" --no-cli-pager >/dev/null \
      || die "Connect rejected the updated content for flow \"$name\"."
    ok "Flow \"$name\" updated ($id)."
  else
    id="$(aws connect create-contact-flow \
        --region "$region" --instance-id "$instance_id" \
        --name "$name" --type CONTACT_FLOW --status PUBLISHED \
        --description "Deployed by deploy_connect_lambdas.sh" \
        --content "file://$prepared" \
        --query 'ContactFlowId' --output text --no-cli-pager)" \
      || die "Connect rejected flow \"$name\". Fix the reported reference and re-run."
    ok "Flow \"$name\" created ($id)."
  fi
  DEPLOYED_FLOW_ID="$id"
}

associate_lex_bot() { # associate_lex_bot <region> <instance-id>
  local region="$1" instance_id="$2" existing output
  if existing="$(aws connect list-bots \
        --region "$region" --instance-id "$instance_id" --lex-version V2 \
        --query 'LexBots[].LexV2Bot.AliasArn' --output text 2>/dev/null)"; then
    if tr '\t' '\n' <<<"$existing" | grep -qxF -- "$LEX_ALIAS_ARN"; then
      ok "Lex bot alias already associated with instance $instance_id."
      return 0
    fi
  fi
  if output="$(aws connect associate-bot \
        --region "$region" --instance-id "$instance_id" \
        --lex-v2-bot "AliasArn=$LEX_ALIAS_ARN" 2>&1)"; then
    ok "Associated Lex bot $LEX_BOT_NAME ($LEX_ALIAS_NAME) with instance $instance_id."
  elif grep -qi "ResourceConflict\|DuplicateResource" <<<"$output"; then
    ok "Lex bot already associated with instance $instance_id."
  else
    die "Could not associate the Lex bot with instance $instance_id: $output"
  fi
}

associate_assistant() { # associate_assistant <region> <instance-id>
  local region="$1" instance_id="$2" existing output
  if existing="$(aws connect list-integration-associations \
        --region "$region" --instance-id "$instance_id" \
        --integration-type WISDOM_ASSISTANT \
        --query 'IntegrationAssociationSummaryList[].IntegrationArn' \
        --output text 2>/dev/null)"; then
    if tr '\t' '\n' <<<"$existing" | grep -qxF -- "$ASSISTANT_ARN"; then
      ok "Q in Connect assistant already associated with instance $instance_id."
      return 0
    fi
  fi
  if output="$(aws connect create-integration-association \
        --region "$region" --instance-id "$instance_id" \
        --integration-type WISDOM_ASSISTANT \
        --integration-arn "$ASSISTANT_ARN" 2>&1)"; then
    ok "Associated Q in Connect assistant with instance $instance_id."
  else
    warn "Could not associate the Q in Connect assistant automatically: $output"
    warn "If the flow fails to create, enable Amazon Q in Connect on instance $instance_id and re-run."
  fi
}

# Instance #1: GET lambda + the transfer-to-number flow.
deploy_flow "$GET_REGION" "$GET_INSTANCE_ID" "$FLOW_FILE_1" "$FLOW_NAME_1" \
  "arn:aws:lambda:${GET_REGION}:${ACCOUNT_ID}:function:${GET_FN}" "$GET_FN"
FLOW_ID_1="$DEPLOYED_FLOW_ID"

# Instance #2: SAVE lambda + the AI agent IVR flow, which also needs the Lex bot
# and the Q in Connect assistant wired to the instance.
associate_lex_bot  "$SAVE_REGION" "$SAVE_INSTANCE_ID"
associate_assistant "$SAVE_REGION" "$SAVE_INSTANCE_ID"
deploy_flow "$SAVE_REGION" "$SAVE_INSTANCE_ID" "$FLOW_FILE_2" "$FLOW_NAME_2" \
  "arn:aws:lambda:${SAVE_REGION}:${ACCOUNT_ID}:function:${SAVE_FN}" "$SAVE_FN" with-ai
FLOW_ID_2="$DEPLOYED_FLOW_ID"

#-------------------------------------------------------------------------------
# 6. Smoke test - write through the save function, read back through the get one
#-------------------------------------------------------------------------------
RUN_TEST="$(ask 'Run a quick end-to-end smoke test?' 'y')"
if [[ "$RUN_TEST" =~ ^[Yy] ]]; then
  TEST_NUMBER="+15551234567"
  cat >"$WORKDIR/save_payload.json" <<EOF
{"Details":{"Parameters":{"CustomerNumber":"$TEST_NUMBER","ModelNumber":"Archer AX73"}}}
EOF
  cat >"$WORKDIR/get_payload.json" <<EOF
{"Details":{"Parameters":{"CustomerNumber":"$TEST_NUMBER"}}}
EOF

  log "Invoking $SAVE_FN ($SAVE_REGION) ..."
  aws lambda invoke --region "$SAVE_REGION" --function-name "$SAVE_FN" \
    --cli-binary-format raw-in-base64-out \
    --payload "file://$WORKDIR/save_payload.json" \
    "$WORKDIR/save_out.json" --no-cli-pager >/dev/null
  echo "  -> $(cat "$WORKDIR/save_out.json")"

  log "Invoking $GET_FN ($GET_REGION) ..."
  aws lambda invoke --region "$GET_REGION" --function-name "$GET_FN" \
    --cli-binary-format raw-in-base64-out \
    --payload "file://$WORKDIR/get_payload.json" \
    "$WORKDIR/get_out.json" --no-cli-pager >/dev/null
  echo "  -> $(cat "$WORKDIR/get_out.json")"

  # Remove the probe record so repeated runs do not pile up test data.
  TEST_CREATED_AT="$(sed -n 's/.*"CreatedAt"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$WORKDIR/save_out.json" | head -n 1)"
  if [[ -n "$TEST_CREATED_AT" ]]; then
    aws dynamodb delete-item \
      --region "$TABLE_REGION" --table-name "$TABLE_NAME" \
      --key "{\"CustomerNumber\":{\"S\":\"$TEST_NUMBER\"},\"CreatedAt\":{\"S\":\"$TEST_CREATED_AT\"}}" \
      --no-cli-pager >/dev/null && ok "Smoke-test record removed."
  else
    warn "Could not determine the smoke-test record key, leaving it in the table."
  fi
fi

#-------------------------------------------------------------------------------
# Summary
#-------------------------------------------------------------------------------
cat <<EOF

==============================================================
 Deployment complete
==============================================================
 DynamoDB table : $TABLE_NAME  (region $TABLE_REGION, shared by both functions)
   Partition key: CustomerNumber (String)
   Sort key     : CreatedAt      (String, ISO-8601 UTC)

 Instance #1    : $GET_INSTANCE_ALIAS  ($GET_INSTANCE_ID, $GET_REGION)
   GET function : arn:aws:lambda:${GET_REGION}:${ACCOUNT_ID}:function:${GET_FN}
     Input      : CustomerNumber
     Returns    : Status, Found, CustomerNumber, ModelNumber, CreatedAt
   Flow         : $FLOW_NAME_1  ($FLOW_ID_1)

 Instance #2    : $SAVE_INSTANCE_ALIAS  ($SAVE_INSTANCE_ID, $SAVE_REGION)
   SAVE function: arn:aws:lambda:${SAVE_REGION}:${ACCOUNT_ID}:function:${SAVE_FN}
     Input      : CustomerNumber, ModelNumber
     Returns    : Status, CustomerNumber, ModelNumber, CreatedAt
   Flow         : $FLOW_NAME_2  ($FLOW_ID_2)
   Lex V2 bot   : $LEX_BOT_ARN  (alias $LEX_ALIAS_NAME)
   AI agent     : $AI_AGENT_ARN

 Both flows are published and already point at the Lambda function,
 Lex bot and AI agent listed above. Flow results are read back with
 \$.External.ModelNumber and \$.External.Found.

 Still to do by hand:
   - claim or point a phone number at each flow
   - review the outbound number in "$FLOW_NAME_1"
     (TransferParticipantToThirdParty still carries the number from the
     original export)

 If CustomerNumber is omitted, both functions fall back to the
 caller's number (Details.ContactData.CustomerEndpoint.Address).
==============================================================
EOF
