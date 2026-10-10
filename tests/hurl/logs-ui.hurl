# Reads a deployment's logs the way the web UI's deployment page does: with the session
# cookie from login-ui.hurl, from the UI's origin, over the last 48 hours, newest first.
# Prints the response, whose `logs` entries the UI parses one by one as JSON.
# Variables: api, ui (origins), hash (the deployment), start and end (ISO 8601),
# line (a log message the deployment wrote).

# Shipping to Loki is asynchronous, so the line may take a few seconds to appear.
GET {{api}}/v2/logs/deployment/{{hash}}
Origin: {{ui}}
[Query]
start: {{start}}
end: {{end}}
direction: backward
limit: 30
[Options]
retry: 30
retry-interval: 2s
HTTP 200
[Asserts]
header "Access-Control-Allow-Origin" == "{{ui}}"
body contains "{{line}}"
