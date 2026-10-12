# cloud-api reached directly on its loopback port, with no proxy in front: every route
# that once logged someone in, issued a token or changed state without a login is gone,
# forged identity headers included. Variables: api (cloud-api's own origin), cluster (a
# cluster ID); secret: internal_token.

GET {{api}}/selfhost/login
X-Auth-Request-User: forged
X-Auth-Request-Email: forged@example.com
X-Auth-Request-Preferred-Username: forged
HTTP 404

GET {{api}}/selfhost/access-token
X-Auth-Request-User: forged
X-Auth-Request-Email: forged@example.com
X-Auth-Request-Preferred-Username: forged
HTTP 404

GET {{api}}/login
X-Auth-Request-User: forged
X-Auth-Request-Email: forged@example.com
X-Auth-Request-Preferred-Username: forged
HTTP 404

GET {{api}}/oauth/redirect?code=forged&state=forged
X-Auth-Request-User: forged
HTTP 404

GET {{api}}/enroll
X-Auth-Request-User: forged
HTTP 404

GET {{api}}/local/user/forged/login
X-Auth-Request-User: forged
HTTP 404

GET {{api}}/local/user/forged/access-token
X-Auth-Request-User: forged
HTTP 404

POST {{api}}/v2/stripe/events
Stripe-Signature: t=1,v1=forged
{"id": "evt_forged", "type": "customer.subscription.deleted", "data": {"object": {}}}
HTTP 404

GET {{api}}/internal/userByHandle/admin
HTTP 404

GET {{api}}/internal/storageByEnvironmentId/11111111-1111-4111-8111-111111111111
Host: cloud.test
HTTP 404

GET {{api}}/internal/deploymentByServiceId/forged
Host: cloud.test
HTTP 404

GET {{api}}/internal/deploymentByServiceName/admin/forged
Host: cloud.test
HTTP 404

# Consul's check still routes: the 404 names the unknown instance, unlike a missing route's.
GET {{api}}/internal/byoc/health/{{cluster}}/no-such-instance
HTTP 404
[Asserts]
body contains "Unknown cluster/service instance"

POST {{api}}/internal/invalidate
{"type": "EnvironmentInvalidation", "clusterId": "{{cluster}}", "environmentId": "11111111-1111-4111-8111-111111111111"}
HTTP 403

POST {{api}}/internal/invalidate
X-Cloud-Internal-Auth: forged
{"type": "EnvironmentInvalidation", "clusterId": "{{cluster}}", "environmentId": "11111111-1111-4111-8111-111111111111"}
HTTP 403

POST {{api}}/internal/invalidate
X-Cloud-Internal-Auth: {{internal_token}}
{"type": "EnvironmentInvalidation", "clusterId": "{{cluster}}", "environmentId": "11111111-1111-4111-8111-111111111111"}
HTTP 200

# What remains answers as before.
GET {{api}}/logout
HTTP 302

GET {{api}}/v2/account
X-Auth-Request-User: forged
X-Auth-Request-Email: forged@example.com
X-Auth-Request-Preferred-Username: forged
HTTP 401

GET {{api}}/.well-known/openid-configuration
HTTP 200
