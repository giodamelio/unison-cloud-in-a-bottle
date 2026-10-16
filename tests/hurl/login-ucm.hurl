# ucm's `auth.login`, driven by hand: discovery, authorization code with PKCE through the
# login provider, the token exchange, userinfo, and refreshes without client_id. Codes and
# refresh tokens each work once. Prints the final token response, whose `access_token` the
# cloud client can use and whose `refresh_token` is unused.
# Variables: api (origin), user (the provider login, an email), handle, redirect (a
# loopback URL with a listener on it, standing in for ucm's), verifier and challenge (a
# PKCE S256 pair); secret: password.

GET {{api}}/.well-known/openid-configuration
HTTP 200
[Captures]
authorize: jsonpath "$.authorization_endpoint"
token_endpoint: jsonpath "$.token_endpoint"
userinfo: jsonpath "$.userinfo_endpoint"

GET {{authorize}}
[Query]
response_type: code
client_id: ucm
redirect_uri: {{redirect}}
scope: openid cloud sync
state: hurl-state
code_challenge: {{challenge}}
code_challenge_method: S256
[Options]
location: true
HTTP 200
[Captures]
action: xpath "string(//form/@action)"
provider: url regex "^(https?://[^/]+)"

# The redirects end at the loopback listener, which answers 404 for any path.
POST {{provider}}{{action}}
[Options]
location: true
[FormParams]
login: {{user}}
password: {{password}}
HTTP 404
[Captures]
code: url regex "[?&]code=([^&]+)"
[Asserts]
url startsWith "{{redirect}}"
url contains "state=hurl-state"

POST {{token_endpoint}}
[FormParams]
grant_type: authorization_code
code: {{code}}
redirect_uri: {{redirect}}
client_id: ucm
code_verifier: {{verifier}}
HTTP 200
[Captures]
access_token: jsonpath "$.access_token"
refresh_token: jsonpath "$.refresh_token"

# A code is single-use.
POST {{token_endpoint}}
[FormParams]
grant_type: authorization_code
code: {{code}}
redirect_uri: {{redirect}}
client_id: ucm
code_verifier: {{verifier}}
HTTP 400
[Asserts]
jsonpath "$.error" == "invalid_grant"

GET {{userinfo}}
Authorization: Bearer {{access_token}}
HTTP 200
[Asserts]
jsonpath "$.handle" == "{{handle}}"
jsonpath "$.sub" startsWith "U-"

GET {{api}}/v2/account
Authorization: Bearer {{access_token}}
HTTP 200
[Asserts]
jsonpath "$.handle" == "{{handle}}"

# ucm refreshes without sending client_id.
POST {{token_endpoint}}
[FormParams]
grant_type: refresh_token
refresh_token: {{refresh_token}}
HTTP 200
[Captures]
next_refresh_token: jsonpath "$.refresh_token"

# A refresh token is single-use too.
POST {{token_endpoint}}
[FormParams]
grant_type: refresh_token
refresh_token: {{refresh_token}}
HTTP 400
[Asserts]
jsonpath "$.error" == "invalid_grant"

POST {{token_endpoint}}
[FormParams]
grant_type: refresh_token
refresh_token: {{next_refresh_token}}
HTTP 200
[Asserts]
jsonpath "$.access_token" exists
