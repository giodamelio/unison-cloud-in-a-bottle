# Plays the browser that ucm's `auth.login` opens: follows the authorization URL to the
# login form, logs in, and follows the redirects back to ucm's loopback listener.
# Variables: api (origin), url (the URL ucm opened), user; secret: password.

GET {{url}}
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
HTTP *
[Asserts]
url startsWith "http://"
url contains "code="
