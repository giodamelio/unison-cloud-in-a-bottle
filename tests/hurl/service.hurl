# Calls a deployed service and checks its whole response body.
# Variables: url (the service URL the deploy program printed), expected (the body).

GET {{url}}
HTTP 200
[Asserts]
body == "{{expected}}"
