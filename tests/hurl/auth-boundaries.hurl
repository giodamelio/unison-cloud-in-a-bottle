# What the API domain refuses without a login. Variables: api, authorize (the
# provider's authorization endpoint); secret: token.

# Logging in starts at the provider.
GET {{api}}/login
HTTP 302
[Asserts]
header "Location" startsWith "{{authorize}}?"

# The header-trust routes are unreachable, so forged identity headers get nowhere.
GET {{api}}/selfhost/access-token
X-Auth-Request-User: forged
X-Auth-Request-Email: forged@example.com
X-Auth-Request-Preferred-Username: forged
HTTP 404

GET {{api}}/selfhost/login
X-Auth-Request-User: forged
X-Auth-Request-Email: forged@example.com
X-Auth-Request-Preferred-Username: forged
HTTP 404

GET {{api}}/local/access-token?username=forged
HTTP 404

GET {{api}}/oauth/authorize
HTTP 404

GET {{api}}/internal/byoc/health
HTTP 404

# ucm's authorization endpoint only issues codes to loopback redirect URIs.
GET {{api}}/selfhost/oidc/authorize?response_type=code&client_id=ucm&redirect_uri=https%3A%2F%2Fevil.example%2Fcb&scope=openid&state=s&code_challenge=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&code_challenge_method=S256
HTTP 400

GET {{api}}/selfhost/oidc/userinfo
HTTP 401

GET {{api}}/v2/account
HTTP 401

GET {{api}}/v2/account
Authorization: Bearer {{token}}
HTTP 200
