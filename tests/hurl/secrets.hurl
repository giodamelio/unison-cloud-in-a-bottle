# cloud-api's Vault-compatible secrets listener, driven the way nimbus drives it.
# Variables: base (http://host:port), token (the cluster token), env (an environment
# UUID in the token's cluster), other_env (an environment in another cluster).

GET {{base}}/v1/environments/data/{{env}}
X-Vault-Token: {{token}}
HTTP 404

POST {{base}}/v1/environments/data/{{env}}
X-Vault-Token: {{token}}
{"options": {"cas": 0}, "data": {"A": "1", "B": "2"}}
HTTP 200
[Asserts]
jsonpath "$.data.version" == 1

# A second create-only write is refused; nimbus treats this 400 as "already exists".
POST {{base}}/v1/environments/data/{{env}}
X-Vault-Token: {{token}}
{"options": {"cas": 0}, "data": {"A": "changed"}}
HTTP 400

PATCH {{base}}/v1/environments/data/{{env}}
X-Vault-Token: {{token}}
Content-Type: application/merge-patch+json
{"data": {"A": null, "C": "3"}}
HTTP 200
[Asserts]
jsonpath "$.data.version" == 2

GET {{base}}/v1/environments/data/{{env}}
X-Vault-Token: {{token}}
HTTP 200
[Asserts]
jsonpath "$.data.data.A" not exists
jsonpath "$.data.data.B" == "2"
jsonpath "$.data.data.C" == "3"
jsonpath "$.data.metadata.version" == 2

# The shape nimbus's environment.fetchVersion decodes, not real Vault's.
GET {{base}}/v1/environments/metadata/{{env}}
X-Vault-Token: {{token}}
HTTP 200
[Asserts]
jsonpath "$.data.data.B" == "2"
jsonpath "$.version" == 2

GET {{base}}/v1/environments/data/{{env}}
X-Vault-Token: wrong
HTTP 403

GET {{base}}/v1/environments/data/{{env}}
HTTP 403

GET {{base}}/v1/environments/data/{{other_env}}
X-Vault-Token: {{token}}
HTTP 403

GET {{base}}/v1/other-mount/data/{{env}}
X-Vault-Token: {{token}}
HTTP 404

DELETE {{base}}/v1/environments/data/{{env}}
X-Vault-Token: {{token}}
HTTP 204

GET {{base}}/v1/environments/data/{{env}}
X-Vault-Token: {{token}}
HTTP 404
