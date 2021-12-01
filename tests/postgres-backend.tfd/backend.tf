terraform {
  backend "pg" {
    # Format: postgres://user:password@host/database[?sslmode=disable]
    #conn_str = "postgres://postgres:password@postgres/postgres?sslmode=disable"
    # This can also be passed via "-backend-config=conn_str=..."
  }
}
