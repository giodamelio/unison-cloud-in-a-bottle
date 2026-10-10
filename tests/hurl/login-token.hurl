# Log in through the bundled Dex and print a cloud-api access token.
# Variables: api (origin), user (the Dex login, an email); secret: password.

GET {{api}}/selfhost/access-token
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
body matches /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/
