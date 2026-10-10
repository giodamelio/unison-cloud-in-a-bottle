"""Call one DynamoDB operation, signed the way nimbus signs it.

nimbus's local DynamoDB mode signs with an empty region, which the AWS CLI can't
do, so both the table setup and the tests go through this.
"""

import argparse
import json
import ssl
import sys
import urllib.error
import urllib.request

from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
from botocore.credentials import Credentials


def read(path):
    with open(path) as f:
        return f.read().strip()


parser = argparse.ArgumentParser()
parser.add_argument("--endpoint", required=True)
parser.add_argument("--region", default="")
parser.add_argument("--ca-file", required=True)
parser.add_argument("--access-key-id-file", required=True)
parser.add_argument("--secret-access-key-file", required=True)
parser.add_argument("operation")
parser.add_argument("body", help="request body as JSON")
args = parser.parse_args()

body = json.dumps(json.loads(args.body)).encode()
request = AWSRequest(
    method="POST",
    url=args.endpoint.rstrip("/") + "/",
    data=body,
    headers={
        "Content-Type": "application/x-amz-json-1.0",
        "X-Amz-Target": f"DynamoDB_20120810.{args.operation}",
    },
)
credentials = Credentials(read(args.access_key_id_file), read(args.secret_access_key_file))
SigV4Auth(credentials, "dynamodb", args.region).add_auth(request)

context = ssl.create_default_context(cafile=args.ca_file)
http_request = urllib.request.Request(request.url, data=body, headers=dict(request.headers), method="POST")
try:
    with urllib.request.urlopen(http_request, context=context) as response:
        print(response.read().decode())
except urllib.error.HTTPError as e:
    print(f"{args.operation} failed with HTTP {e.code}: {e.read().decode()}", file=sys.stderr)
    sys.exit(1)
