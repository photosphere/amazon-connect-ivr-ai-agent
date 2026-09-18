"""Amazon Connect -> DynamoDB: return the newest ModelNumber for a customer.

Queries the table by CustomerNumber in descending sort-key order and returns
the first hit, i.e. the most recently inserted record.

The stored ModelNumber may be either a bare model ("Deco X50(CA)") or a
pipe-delimited bundle that also carries category and description
("model: Deco X50(CA) | category: Deco | description: keeps dropping Wi-Fi").
Both shapes are parsed into separate ModelNumber / Category / Description
response attributes.
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


# Recognised labels inside the pipe-delimited form, mapped to output keys.
_LABELS = {
    "model": "ModelNumber",
    "modelnumber": "ModelNumber",
    "model number": "ModelNumber",
    "category": "Category",
    "description": "Description",
    "desc": "Description",
    "issue": "Description",
}
# Positional fallback when segments carry no labels at all.
_POSITIONAL = ("ModelNumber", "Category", "Description")


def parse_model_field(raw):
    """Split a stored ModelNumber into ModelNumber / Category / Description.

    Supports the bare form ("Deco X50(CA)") and the labelled pipe-delimited
    form ("model: X | category: Y | description: Z"), in any label order and
    with any subset of labels present. Unlabelled segments fall back to
    model / category / description by position.
    """
    parsed = {"ModelNumber": "", "Category": "", "Description": ""}
    if not raw:
        return parsed

    # Normalise full-width punctuation that can sneak in from transcriptions.
    text = str(raw).replace("｜", "|").replace("：", ":").strip()
    if not text:
        return parsed

    position = 0
    for segment in text.split("|"):
        segment = segment.strip()
        if not segment:
            continue

        key = None
        value = segment
        if ":" in segment:
            label, _, remainder = segment.partition(":")
            label = label.strip().lower()
            if label in _LABELS:
                key = _LABELS[label]
                value = remainder

        if key is None:
            # Unlabelled segment: assign by position, skipping slots that a
            # labelled segment already filled.
            while position < len(_POSITIONAL) and parsed[_POSITIONAL[position]]:
                position += 1
            if position >= len(_POSITIONAL):
                continue
            key = _POSITIONAL[position]
            position += 1

        value = value.strip()
        if value and not parsed[key]:
            parsed[key] = value

    return parsed


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
                    "Category": "",
                    "Description": "",
                    "CustomerNumber": normalize_number(customer_number),
                    "Message": "Table does not exist yet, no records stored.",
                }
            raise

        items = response.get("Items") or []
        if items:
            item = items[0]
            parsed = parse_model_field(item.get("ModelNumber", ""))
            # Dedicated attributes, when present on the item, win over anything
            # parsed out of the combined ModelNumber string.
            for attribute in ("Category", "Description"):
                value = item.get(attribute)
                if value not in (None, ""):
                    parsed[attribute] = str(value).strip()

            result = {
                "Status": "SUCCESS",
                "Found": "true",
                "CustomerNumber": key,
                "ModelNumber": parsed["ModelNumber"],
                "Category": parsed["Category"],
                "Description": parsed["Description"],
                "CreatedAt": item.get("CreatedAt", ""),
            }
            LOG.info("Result: %s", json.dumps(result))
            return result

    return {
        "Status": "SUCCESS",
        "Found": "false",
        "CustomerNumber": normalize_number(customer_number),
        "ModelNumber": "",
        "Category": "",
        "Description": "",
        "Message": "No record found for this customer number.",
    }
