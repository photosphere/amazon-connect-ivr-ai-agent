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
