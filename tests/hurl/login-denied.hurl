# A provider user outside the allowlist authenticates but is refused, and gets no session.
# Variables: api, user; secret: password.

GET {{api}}/login
[Options]
location: true
HTTP 200
[Captures]
action: xpath "string(//form/@action)"

POST {{api}}{{action}}
[Options]
location: true
[FormParams]
login: {{user}}
password: {{password}}
HTTP 403
[Asserts]
cookie "cloud-session" not exists
