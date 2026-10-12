# ucm's `auth.login` against cloud-api and Dex on the namespace loopback, for tests with no
# reverse proxy. Dex's URLs are on the public origin, which nothing serves here, so run
# with `--connect-to <public host>:<port>:127.0.0.1:<Dex's port>`. cloud-api's callback is
# on that origin too, so it's sent to cloud-api's loopback by hand. Prints the token
# response, whose `access_token` the cloud client can use.
# Variables: api (cloud-api's loopback origin), user (a Dex login, an email), verifier and
# challenge (a PKCE S256 pair); secret: password.

GET {{api}}/selfhost/oidc/authorize
[Query]
response_type: code
client_id: ucm
redirect_uri: http://127.0.0.1:8099/redirect
scope: openid cloud sync
state: hurl-state
code_challenge: {{challenge}}
code_challenge_method: S256
HTTP 302
[Captures]
pending: cookie "selfhost-oidc-pending"
dex_auth: header "Location"

GET {{dex_auth}}
[Options]
location: true
HTTP 200
[Captures]
action: xpath "string(//form/@action)"
provider: url regex "^(https?://[^/]+)"

POST {{provider}}{{action}}
[FormParams]
login: {{user}}
password: {{password}}
# Dex skips its approval screen and redirects straight to cloud-api's callback.
HTTP 303
[Captures]
callback: header "Location" regex "^https?://[^/]+(/selfhost/oidc/callback\\?.*)$"

GET {{api}}{{callback}}
Cookie: selfhost-oidc-pending={{pending}}
HTTP 302
[Captures]
code: header "Location" regex "[?&]code=([^&]+)"
[Asserts]
header "Location" startsWith "http://127.0.0.1:8099/redirect?"

POST {{api}}/selfhost/oidc/token
[FormParams]
grant_type: authorization_code
code: {{code}}
redirect_uri: http://127.0.0.1:8099/redirect
client_id: ucm
code_verifier: {{verifier}}
HTTP 200
