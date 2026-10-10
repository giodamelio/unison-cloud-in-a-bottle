self: {
  name = "unison-cloud-extenddb";

  nodes.machine = {config, ...}: {
    imports = [self.nixosModules.default];

    services.unison-cloud = {
      enable = true;
      domains = {
        api = "cloud.test";
        apps = "apps.test";
        ui = "ui.test";
      };
    };

    environment.systemPackages = [config.services.unison-cloud.internal.dynamoCall];

    virtualisation.memorySize = 2048;
  };

  testScript = ''
    import json
    import shlex

    secrets = "/var/lib/unison-cloud/secrets"
    table = "unison-cloud"

    def dynamo(op, body, secret_file=f"{secrets}/extenddb-secret-access-key", expect_ok=True):
        cmd = (
            "ip netns exec unison-cloud unison-cloud-dynamo-call"
            " --endpoint https://127.0.0.1:18443"
            f" --ca-file {secrets}/ca.crt"
            f" --access-key-id-file {secrets}/extenddb-access-key-id"
            f" --secret-access-key-file {secret_file}"
            f" {op} {shlex.quote(json.dumps(body))}"
        )
        if expect_ok:
            return json.loads(machine.succeed(cmd))
        return machine.fail(cmd)

    def key(k):
        return {"K": {"B": k}, "NS": {"S": "db:tbl"}}

    def write(k, v, condition, values):
        return {
            "Update": {
                "TableName": table,
                "Key": key(k),
                "UpdateExpression": "SET V = :v ADD T :i",
                "ConditionExpression": condition,
                "ExpressionAttributeValues": {":v": {"B": v}, ":i": {"N": "1"}, **values},
            }
        }

    def get(k):
        return dynamo("GetItem", {
            "TableName": table,
            "Key": key(k),
            "ConsistentRead": True,
            "ProjectionExpression": "V, T",
        }).get("Item")

    machine.wait_for_unit("unison-cloud-extenddb-setup.service")

    with subtest("nimbus's table exists with its key schema"):
        schema = dynamo("DescribeTable", {"TableName": table})["Table"]["KeySchema"]
        assert sorted((k["AttributeName"], k["KeyType"]) for k in schema) == [("K", "HASH"), ("NS", "RANGE")], schema

    with subtest("an empty SigV4 region is accepted"):
        dynamo("ListTables", {})

    with subtest("a wrong secret is rejected"):
        machine.succeed("echo wrong > /tmp/wrong-secret")
        dynamo("ListTables", {}, secret_file="/tmp/wrong-secret", expect_ok=False)

    with subtest("first write creates the item"):
        dynamo("TransactWriteItems", {"TransactItems": [write("azE=", "djE=", "attribute_not_exists(K)", {})]})
        item = get("azE=")
        assert item == {"V": {"B": "djE="}, "T": {"N": "1"}}, item

    with subtest("a second create of the same key is cancelled"):
        dynamo("TransactWriteItems", {"TransactItems": [write("azE=", "djI=", "attribute_not_exists(K)", {})]}, expect_ok=False)

    with subtest("a write with the current version succeeds"):
        dynamo("TransactWriteItems", {"TransactItems": [write("azE=", "djI=", "T = :t", {":t": {"N": "1"}})]})
        item = get("azE=")
        assert item == {"V": {"B": "djI="}, "T": {"N": "2"}}, item

    with subtest("a write with a stale version is cancelled and changes nothing"):
        dynamo("TransactWriteItems", {"TransactItems": [write("azE=", "djE=", "T = :t", {":t": {"N": "1"}})]}, expect_ok=False)
        assert get("azE=")["T"] == {"N": "2"}

    with subtest("BatchGetItem returns every key"):
        dynamo("TransactWriteItems", {"TransactItems": [write("azI=", "djE=", "attribute_not_exists(K)", {})]})
        response = dynamo("BatchGetItem", {"RequestItems": {table: {
            "ConsistentRead": True,
            "ProjectionExpression": "K, V, T",
            "Keys": [key("azE="), key("azI=")],
        }}})
        assert sorted(i["K"]["B"] for i in response["Responses"][table]) == ["azE=", "azI="], response

    with subtest("ConditionCheck and Delete commit together"):
        dynamo("TransactWriteItems", {"TransactItems": [
            {"ConditionCheck": {
                "TableName": table,
                "Key": key("azE="),
                "ConditionExpression": "T = :t",
                "ExpressionAttributeValues": {":t": {"N": "2"}},
            }},
            {"Delete": {"TableName": table, "Key": key("azI=")}},
        ]})
        assert get("azI=") is None

    with subtest("a restart migrates instead of initializing and reuses the existing setup"):
        # Requires= restarts the setup unit along with ExtendDB.
        machine.systemctl("restart unison-cloud-extenddb.service")
        machine.wait_for_unit("unison-cloud-extenddb-setup.service")
        machine.succeed("journalctl -u unison-cloud-extenddb.service | grep -q 'extenddb migrate'")
        assert get("azE=")["T"] == {"N": "2"}

    with subtest("Postgres has no TCP listener"):
        machine.fail("ip netns exec unison-cloud ss -Hltn | grep -q 5432")
        machine.fail("ss -Hltn | grep -q 5432")
  '';
}
