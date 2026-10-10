# The web UI's login: /login through Dex, back to the UI with a session cookie.
# Variables: api, ui (origins), user, handle; secret: password.

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
HTTP 200
[Asserts]
url == "{{ui}}/"

# The cookie jar now holds cloud-api's session cookie for the API origin.
GET {{api}}/v2/account
HTTP 200
[Asserts]
jsonpath "$.handle" == "{{handle}}"
