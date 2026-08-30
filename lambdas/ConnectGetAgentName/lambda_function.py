"""Amazon Connect -> Connect: turn a Connect user id into an agent name.

The screen-pop flow reads the caller's "_last_agent_id" calculated attribute,
which is a Connect user id (a UUID) and therefore meaningless to an agent. This
function resolves it to "FirstName LastName" so the agent workspace can show it.

Returns a flat string map, which is what Amazon Connect contact flows expect.
Never raises on a lookup miss: an unresolvable id yields an empty LastAgentName
so the screen pop still renders.
"""
import os
import json
import logging

import boto3
from botocore.exceptions import ClientError

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

# Set by the deploy script. Falls back to the calling contact's own instance,
# which keeps the function usable from a hand-made test event too.
CONNECT_INSTANCE_ID = os.environ.get("CONNECT_INSTANCE_ID", "")
CONNECT_REGION = os.environ.get("CONNECT_REGION") or os.environ["AWS_REGION"]

_connect = boto3.client("connect", region_name=CONNECT_REGION)

# describe_user is called on every contact, and an agent's name almost never
# changes, so a warm container can answer from memory.
_name_cache = {}


def extract(event):
    """Read LastAgentID and the instance id out of any of the shapes Connect,
    the Lambda console and API Gateway send."""
    details = event.get("Details") or {}
    params = details.get("Parameters") or {}
    contact = details.get("ContactData") or {}

    agent_id = params.get("LastAgentID") or params.get("AgentId") or ""
    instance_id = CONNECT_INSTANCE_ID

    if not agent_id and event.get("body"):
        try:
            body = json.loads(event["body"])
        except (TypeError, ValueError):
            body = {}
        agent_id = body.get("LastAgentID") or body.get("AgentId") or ""
    if not agent_id:
        agent_id = event.get("LastAgentID") or event.get("AgentId") or ""

    if not instance_id:
        # arn:aws:connect:<region>:<acct>:instance/<uuid>
        instance_arn = contact.get("InstanceARN") or ""
        if "/" in instance_arn:
            instance_id = instance_arn.rsplit("/", 1)[-1]
    if not instance_id:
        instance_id = event.get("InstanceId") or ""

    return str(agent_id).strip(), str(instance_id).strip()


def lookup_name(instance_id, agent_id):
    key = (instance_id, agent_id)
    if key in _name_cache:
        return _name_cache[key]

    user = _connect.describe_user(UserId=agent_id, InstanceId=instance_id)
    identity = (user.get("User") or {}).get("IdentityInfo") or {}
    name = " ".join(part for part in (identity.get("FirstName"),
                                      identity.get("LastName")) if part).strip()
    # An agent may exist without a first/last name, in which case the login name
    # is still more useful to another agent than a bare UUID.
    if not name:
        name = (user.get("User") or {}).get("Username") or ""

    _name_cache[key] = name
    return name


def lambda_handler(event, context):
    LOG.info("Event: %s", json.dumps(event, default=str))
    agent_id, instance_id = extract(event)

    if not agent_id:
        LOG.info("No LastAgentID supplied, nothing to resolve.")
        return {"Status": "SUCCESS", "Found": "false",
                "LastAgentID": "", "LastAgentName": ""}

    if not instance_id:
        LOG.warning("No Connect instance id available, cannot resolve %s.", agent_id)
        return {"Status": "ERROR", "Found": "false",
                "LastAgentID": agent_id, "LastAgentName": "",
                "Error": "No Connect instance id available."}

    try:
        name = lookup_name(instance_id, agent_id)
    except ClientError as err:
        code = err.response["Error"]["Code"]
        # A deleted agent, or an id from another instance, is expected in real
        # data. Degrade to an empty name instead of failing the flow.
        if code in ("ResourceNotFoundException", "InvalidParameterException",
                    "InvalidRequestException"):
            LOG.warning("Cannot resolve agent %s in instance %s: %s",
                        agent_id, instance_id, code)
            return {"Status": "SUCCESS", "Found": "false",
                    "LastAgentID": agent_id, "LastAgentName": ""}
        raise

    LOG.info("Agent %s resolved to %r", agent_id, name)
    return {
        "Status": "SUCCESS",
        "Found": "true" if name else "false",
        "LastAgentID": agent_id,
        "LastAgentName": name,
    }
