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
