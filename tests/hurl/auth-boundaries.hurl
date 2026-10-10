# What the API domain refuses without a login. Variables: api; secret: token.

GET {{api}}/selfhost/access-token
HTTP 302
[Asserts]
header "Location" contains "/oauth2/start"

# A forged identity header is stripped before forward_auth, so it changes nothing.
GET {{api}}/selfhost/access-token
X-Auth-Request-User: forged
X-Auth-Request-Email: forged@example.com
X-Auth-Request-Preferred-Username: forged
HTTP 302
[Asserts]
header "Location" contains "/oauth2/start"

GET {{api}}/local/access-token?username=forged
HTTP 404

GET {{api}}/oauth/authorize
HTTP 404

GET {{api}}/internal/byoc/health
HTTP 404

GET {{api}}/v2/account
HTTP 401

GET {{api}}/v2/account
Authorization: Bearer {{token}}
HTTP 200
