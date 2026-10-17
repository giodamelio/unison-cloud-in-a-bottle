# A provider user outside the email allowlist authenticates but is refused, is told why,
# and gets no session.
# Variables: api, user; secret: password.

GET {{api}}/login
[Options]
location: true
HTTP 200
[Captures]
action: xpath "string(//form/@action)"
provider: url regex "^(https?://[^/]+)"

POST {{provider}}{{action}}
[Options]
location: true
[FormParams]
login: {{user}}
password: {{password}}
HTTP 403
[Asserts]
cookie "cloud-session" not exists
body contains "Your email address, {{user}}, isn't one this server lets in."
