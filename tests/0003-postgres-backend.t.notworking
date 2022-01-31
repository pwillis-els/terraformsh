#!/usr/bin/env sh
# vim: syntax=sh
[ "${DEBUG:-0}" = "1" ] && set -x
set -u

POSTGRES_HOST="${POSTGRES_HOST:-postgres}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_DB="${POSTGRES_DB:-postgres}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-password}"

_t_postgres_connection () {
    if env PGPASSWORD="$POSTGRES_PASSWORD" \
        psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -u "$POSTGRES_USER" -c 'SELECT 1;'
    then
        echo "$0: Successfully queried Postgres database"
        return 0
    else
        echo "$0: Error: Could not connect to Postgres database"
        return 1
    fi
}

_t_postgres_backend_plan () {
    cp -a "$testsh_pwd/tests/null-resource-hello-world.tfd/.terraform-version" "$testsh_pwd/tests/null-resource-hello-world.tfd/null-hello-goodbye.tf" "$tmp/"
    cp -a "$testsh_pwd/tests/postgres-backend.tfd/.terraform-version" "$testsh_pwd/tests/postgres-backend.tfd/backend.tf" "$tmp/"
    cd "$tmp"

    # Set the connection string for the backend using the hacky env var method
    # (jesus christ, Hashicorp...)
    
    if env TF_CLI_ARGS_init="-backend-config=conn_str=postgres://$POSTGRES_USER:$POSTGRES_PASSWORD@$POSTGRES_HOST/$POSTGRES_DB" \
        $testsh_pwd/terraformsh plan
    then
        echo "$0: Successfully ran 'terraformsh plan'"
    else
        echo "$0: Error running 'terraformsh plan'"
        return 1
    fi
}

ext_tests="postgres_connection postgres_backend_plan"
