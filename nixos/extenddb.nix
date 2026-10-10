{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.unison-cloud;
  user = "unison-cloud-extenddb";
  home = "${cfg.stateDir}/extenddb";
  secrets = "${cfg.stateDir}/secrets";
  endpoint = "https://127.0.0.1:${toString cfg.extenddb.port}";
  extenddb = lib.getExe cfg.extenddb.package;

  # Fixed so the setup can find what it created on an earlier start.
  accountId = "100000000001";
  iamUser = "nimbus";

  dynamoCall = pkgs.writers.writePython3Bin "unison-cloud-dynamo-call" {
    libraries = [pkgs.python3Packages.botocore];
    flakeIgnore = ["E501"];
  } (builtins.readFile ./dynamo-call.py);

  environment = {
    HOME = home;
    EXTENDDB__SERVER__BIND_ADDR = "127.0.0.1";
    EXTENDDB__SERVER__PORT = toString cfg.extenddb.port;
  };

  setup = pkgs.writeShellApplication {
    name = "unison-cloud-extenddb-setup";
    runtimeInputs = [pkgs.coreutils pkgs.jq dynamoCall];
    text = ''
      creds=$CREDENTIALS_DIRECTORY
      manage() {
        EXTENDDB_PASSWORD=$(< "$creds/admin-password") ${extenddb} manage --user admin --config extenddb.toml "$@"
      }
      contains() {
        jq -e --arg want "$1" 'any(.. | strings; . == $want)' > /dev/null
      }
      dynamo() {
        unison-cloud-dynamo-call --endpoint ${endpoint} --ca-file "$creds/ca" \
          --access-key-id-file "$creds/access-key-id" --secret-access-key-file "$creds/secret-access-key" "$@"
      }

      until ${extenddb} healthcheck --endpoint ${endpoint}; do sleep 1; done

      if ! manage list-accounts | contains ${accountId}; then
        manage create-account --account-id ${accountId} --account-name unison-cloud
      fi
      if ! manage list-users --account-id ${accountId} | contains ${iamUser}; then
        manage create-user --account-id ${accountId} --user-name ${iamUser}
      fi
      manage put-user-policy --account-id ${accountId} --user-name ${iamUser} --policy-name dynamodb \
        --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"dynamodb:*","Resource":"*"}]}'
      access_key_id=$(< "$creds/access-key-id")
      if ! manage list-access-keys --account-id ${accountId} --user-name ${iamUser} | contains "$access_key_id"; then
        manage import-access-key --account-id ${accountId} --user-name ${iamUser} \
          --access-key-id "$access_key_id" --secret-access-key "$(< "$creds/secret-access-key")" --yes
      fi

      if ! dynamo ListTables '{}' | contains ${cfg.extenddb.tableName}; then
        dynamo CreateTable '${builtins.toJSON {
        TableName = cfg.extenddb.tableName;
        AttributeDefinitions = [
          {
            AttributeName = "K";
            AttributeType = "B";
          }
          {
            AttributeName = "NS";
            AttributeType = "S";
          }
        ];
        KeySchema = [
          {
            AttributeName = "K";
            KeyType = "HASH";
          }
          {
            AttributeName = "NS";
            KeyType = "RANGE";
          }
        ];
        BillingMode = "PAY_PER_REQUEST";
      }}'
      fi
      until dynamo DescribeTable '{"TableName":"${cfg.extenddb.tableName}"}' | jq -e '.Table.TableStatus == "ACTIVE"' > /dev/null; do
        sleep 1
      done
    '';
  };
in {
  options.services.unison-cloud.internal.dynamoCall = lib.mkOption {
    type = lib.types.package;
    internal = true;
    readOnly = true;
    default = dynamoCall;
    description = "Client that signs DynamoDB requests with an empty region, as nimbus does.";
  };

  config = lib.mkIf cfg.enable {
    users.users.${user} = {
      isSystemUser = true;
      group = user;
    };
    users.groups.${user} = {};

    services.unison-cloud.internal.postgresRoles.${user}.createdb = true;

    systemd.tmpfiles.settings.unison-cloud-extenddb.${home}.d = {
      inherit user;
      group = user;
      mode = "0700";
    };

    systemd.services.unison-cloud-extenddb = lib.mkMerge [
      cfg.internal.inNamespace
      {
        description = "Unison Cloud DynamoDB store (ExtendDB)";
        wantedBy = ["multi-user.target"];
        requires = ["unison-cloud-postgresql-setup.service" "unison-cloud-secrets.service"];
        after = ["unison-cloud-postgresql-setup.service" "unison-cloud-secrets.service"];
        environment =
          environment
          // {
            EXTENDDB__SERVER__TLS__CERT_PATH = "%d/tls-cert";
            EXTENDDB__SERVER__TLS__KEY_PATH = "%d/tls-key";
          };
        serviceConfig = {
          User = user;
          Group = user;
          WorkingDirectory = home;
          LoadCredential = [
            "admin-password:${secrets}/extenddb-admin-password"
            "tls-cert:${secrets}/extenddb.crt"
            "tls-key:${secrets}/extenddb.key"
          ];
          # `init` refuses to run once its databases exist, so it only runs while there's no config yet.
          # It connects as the service's own role through peer authentication, so the password is never checked.
          ExecStartPre = pkgs.writeShellScript "unison-cloud-extenddb-init" ''
            if [ ! -e extenddb.toml ]; then
              EXTENDDB_ADMIN_USER=admin \
              EXTENDDB_ADMIN_PASSWORD=$(< "$CREDENTIALS_DIRECTORY/admin-password") \
              EXTENDDB_APP_PASSWORD=unused-with-peer-auth \
                ${extenddb} init --config extenddb.toml \
                  --pg-host ${cfg.internal.postgresSocketDir} \
                  --pg-user ${user} --extenddb-user ${user} \
                  --data-db extenddb --bind-addr 127.0.0.1
            else
              ${extenddb} migrate --config extenddb.toml --yes --pg-user ${user}
            fi
          '';
          ExecStart = "${extenddb} serve --foreground --config extenddb.toml";
        };
      }
    ];

    systemd.services.unison-cloud-extenddb-setup = lib.mkMerge [
      cfg.internal.inNamespace
      {
        description = "Create Unison Cloud's ExtendDB user, access key and table";
        wantedBy = ["multi-user.target"];
        requires = ["unison-cloud-extenddb.service"];
        after = ["unison-cloud-extenddb.service"];
        inherit environment;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = user;
          Group = user;
          WorkingDirectory = home;
          TimeoutStartSec = 120;
          LoadCredential = [
            "admin-password:${secrets}/extenddb-admin-password"
            "access-key-id:${secrets}/extenddb-access-key-id"
            "secret-access-key:${secrets}/extenddb-secret-access-key"
            "ca:${secrets}/ca.crt"
          ];
          Environment = ["EXTENDDB__SERVER__TLS__CERT_PATH=%d/ca"];
          ExecStart = lib.getExe setup;
        };
      }
    ];
  };
}
