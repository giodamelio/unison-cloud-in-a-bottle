# Reads the user's logs through cloud-api, which queries Loki.
# Variables: api (cloud-api's base URL), host (the API domain, which picks the cluster),
# token (the user's access token), line (a log message the user's code wrote).

# Shipping to Loki is asynchronous, so the line may take a few seconds to appear.
GET {{api}}/v2/logs
Host: {{host}}
Authorization: Bearer {{token}}
[Options]
retry: 30
retry-interval: 2s
HTTP 200
[Asserts]
body contains "{{line}}"
