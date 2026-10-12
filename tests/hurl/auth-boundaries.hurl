# What the API domain refuses without a login. Variables: api, authorize (the
# provider's authorization endpoint); secret: token.

# Logging in starts at the provider.
GET {{api}}/login
HTTP 302
[Asserts]
header "Location" startsWith "{{authorize}}?"

# Forged identity headers get nowhere; cloud-api has no route that reads them.
GET {{api}}/selfhost/access-token
X-Auth-Request-User: forged
X-Auth-Request-Email: forged@example.com
X-Auth-Request-Preferred-Username: forged
HTTP 404

GET {{api}}/v2/account
X-Auth-Request-User: forged
X-Auth-Request-Email: forged@example.com
X-Auth-Request-Preferred-Username: forged
HTTP 401

GET {{api}}/local/user/forged/access-token
HTTP 404

# cloud-api's internal routes stay off the public domain.
GET {{api}}/internal/byoc/health/d3ee426c-c252-4910-a861-08fccf85fb66/no-such-instance
HTTP 404
[Asserts]
body not contains "Unknown cluster/service instance"

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
