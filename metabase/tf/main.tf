terraform {
  required_providers {
    metabase = {
      source  = "flovouin/metabase"
      version = "~> 0.1"
    }
  }
}

# Variable declarations live in variables.tf.

# ---------------------------
# Provider
# ---------------------------
provider "metabase" {
  endpoint = "${trimsuffix(var.metabase_host, "/")}/api"
  username = var.metabase_username
  password = var.metabase_password
}

# ---------------------------
# Postgres Database
# ---------------------------
resource "metabase_database" "postgres" {
  name = var.pg_display_name

  custom_details = {
    engine = "postgres"
    details_json = jsonencode({
      host     = var.pg_host
      port     = var.pg_port
      dbname   = var.pg_database
      user     = var.pg_user
      password = var.pg_password
      ssl      = var.pg_ssl
    })
    redacted_attributes = ["password"]
  }
}

# ---------------------------
# Existing table lookup
# ---------------------------
resource "metabase_table" "identities" {
  db_id  = metabase_database.postgres.id
  schema = "bi_views"
  name   = "active_identities"
}

resource "metabase_table" "identity_entitlements" {
  db_id  = metabase_database.postgres.id
  schema = "bi_views"
  name   = "identity_entitlements"
}

resource "metabase_table" "accounts" {
  db_id  = metabase_database.postgres.id
  schema = "bi_views"
  name   = "accounts"
}

resource "metabase_table" "orphaned_accounts" {
  db_id  = metabase_database.postgres.id
  schema = "bi_views"
  name   = "orphaned_accounts"
}

resource "metabase_table" "entitlements" {
  db_id  = metabase_database.postgres.id
  schema = "bi_views"
  name   = "entitlements"
}

resource "metabase_table" "entitlement_relations" {
  db_id  = metabase_database.postgres.id
  schema = "bi_views"
  name   = "entitlement_relations"
}

# ---------------------------
# Card (Question)
# ---------------------------
resource "metabase_card" "identities_count" {
  json = jsonencode({
    name                   = "Total Active Humans"
    display                = "scalar"
    description            = null
    cache_ttl              = null
    collection_id          = null
    collection_position    = null
    query_type             = "query"
    parameters             = []
    parameter_mappings     = []
    visualization_settings = {}
    dataset_query = {
      database   = metabase_database.postgres.id
      "lib/type" = "mbql/query"
      stages = [
        {
          "lib/type"     = "mbql.stage/mbql"
          "source-table" = metabase_table.identities.id
          aggregation = [
            [
              "count",
              {
                "lib/uuid" = "a1a3a8fd-7fac-44a3-876d-10fec0bcd274"
              }
            ]
          ]
          filters = [
            [
              "=",
              {
                "lib/uuid" = "ea41ee0e-06d1-4824-b28a-47bec97edaf8"
              },
              [
                "field",
                {
                  "base-type"      = "type/Text"
                  "effective-type" = "type/Text"
                  "lib/uuid"       = "d784532b-bb36-4a08-9de4-efd4bbb4568b"
                },
                metabase_table.identities.fields["identity_kind"]
              ],
              "human"
            ]
          ]
        }
      ]
    }
  })
}

# ---------------------------
# Card: Humans by Department
# ---------------------------
resource "metabase_card" "humans_by_department" {
  json = jsonencode({
    name                   = "Humans by Org Unit"
    display                = "bar"
    description            = null
    cache_ttl              = null
    collection_id          = null
    collection_position    = null
    query_type             = "native"
    parameters             = []
    parameter_mappings     = []
    visualization_settings = {}
    dataset_query = {
      database   = metabase_database.postgres.id
      "lib/type" = "mbql/query"
      stages = [
        {
          "lib/type" = "mbql.stage/native"
          native     = <<-SQL
            SELECT
              department AS org_unit_id,
              COUNT(*) AS humans
            FROM bi_views.active_identities
            WHERE identity_kind = 'human'
            GROUP BY department
            ORDER BY humans DESC
          SQL
        }
      ]
    }
  })
}

# ---------------------------
# Card: Identity Roster
# ---------------------------
resource "metabase_card" "identity_roster" {
  json = jsonencode({
    name                   = "Identity Roster"
    display                = "table"
    description            = null
    cache_ttl              = null
    collection_id          = null
    collection_position    = null
    query_type             = "query"
    parameters             = []
    parameter_mappings     = []
    visualization_settings = {}
    dataset_query = {
      database   = metabase_database.postgres.id
      "lib/type" = "mbql/query"
      stages = [
        {
          "lib/type"     = "mbql.stage/mbql"
          "source-table" = metabase_table.identities.id
          fields = [
            [
              "field",
              {
                "base-type"      = "type/Text"
                "effective-type" = "type/Text"
                "lib/uuid"       = "8730609a-0df1-43cd-af9f-b4ca5542e88f"
              },
              metabase_table.identities.fields["identity_kind"]
            ],
            [
              "field",
              {
                "base-type"      = "type/Text"
                "effective-type" = "type/Text"
                "lib/uuid"       = "664ba4e6-bd06-4cf3-b577-21324c2c1de2"
              },
              metabase_table.identities.fields["display_name"]
            ],
            [
              "field",
              {
                "base-type"      = "type/Text"
                "effective-type" = "type/Text"
                "lib/uuid"       = "1d868459-12b1-445b-a1b6-07c2e97f3f3a"
              },
              metabase_table.identities.fields["email"]
            ],
            [
              "field",
              {
                "base-type"      = "type/Text"
                "effective-type" = "type/Text"
                "lib/uuid"       = "37fdd7d2-56dd-482f-8d34-4c89c8fa1041"
              },
              metabase_table.identities.fields["department"]
            ],
            [
              "field",
              {
                "base-type"      = "type/Text"
                "effective-type" = "type/Text"
                "lib/uuid"       = "f68cd22b-b15f-4c48-b04f-955057d07ff6"
              },
              metabase_table.identities.fields["job_title"]
            ],
            [
              "field",
              {
                "base-type"      = "type/Text"
                "effective-type" = "type/Text"
                "lib/uuid"       = "c6db1ac4-65d2-49fd-94d2-e94a907b1dd9"
              },
              metabase_table.identities.fields["manager_name"]
            ],
            [
              "field",
              {
                "base-type"      = "type/Date"
                "effective-type" = "type/Date"
                "lib/uuid"       = "a195aad3-0891-4db0-9e88-ee7bbb561d38"
              },
              metabase_table.identities.fields["hire_date"]
            ]
          ]
          filters = [
            [
              "=",
              {
                "lib/uuid" = "d41a80be-7e24-4441-885c-58165b76d8ba"
              },
              [
                "field",
                {
                  "base-type"      = "type/Text"
                  "effective-type" = "type/Text"
                  "lib/uuid"       = "a4a71b08-7eb4-453e-b51a-751584c61d1b"
                },
                metabase_table.identities.fields["identity_kind"]
              ],
              "human"
            ]
          ]
          "order-by" = [
            [
              "desc",
              {
                "lib/uuid" = "a7850f22-d90f-4286-9659-2272eb811d04"
              },
              [
                "field",
                {
                  "base-type"      = "type/Date"
                  "effective-type" = "type/Date"
                  "lib/uuid"       = "b6f4b779-2016-4d47-b4b0-9438ea658b29"
                },
                metabase_table.identities.fields["hire_date"]
              ]
            ]
          ]
        }
      ]
    }
  })
}

# ---------------------------
# Card: Active Accounts Without Recent Login
# ---------------------------
resource "metabase_card" "active_accounts_without_recent_login" {
  json = jsonencode({
    name                   = "Active Accounts Without Recent Login"
    display                = "table"
    description            = "Active accounts whose last login is older than 7 days."
    cache_ttl              = null
    collection_id          = null
    collection_position    = null
    query_type             = "query"
    parameters             = []
    parameter_mappings     = []
    visualization_settings = {}
    dataset_query = {
      database   = metabase_database.postgres.id
      "lib/type" = "mbql/query"
      stages = [
        {
          "lib/type"     = "mbql.stage/mbql"
          "source-table" = metabase_table.accounts.id
          fields = [
            [
              "field",
              {
                "base-type"      = "type/Text"
                "effective-type" = "type/Text"
                "lib/uuid"       = "4e53f6dd-8f79-4a7d-b0f2-ebcd6cf0b2eb"
              },
              metabase_table.accounts.fields["username"]
            ],
            [
              "field",
              {
                "base-type"      = "type/Text"
                "effective-type" = "type/Text"
                "lib/uuid"       = "1b9dd849-2759-4f9e-b2d2-c285972bb3cf"
              },
              metabase_table.accounts.fields["source"]
            ],
            [
              "field",
              {
                "base-type"      = "type/Text"
                "effective-type" = "type/Text"
                "lib/uuid"       = "7ea6b731-ef2a-46f9-be71-c8cc745ca4f2"
              },
              metabase_table.accounts.fields["status"]
            ],
            [
              "field",
              {
                "base-type"      = "type/DateTime"
                "effective-type" = "type/DateTime"
                "lib/uuid"       = "76cceeb7-06ec-4402-a1b3-63b0159a7553"
              },
              metabase_table.accounts.fields["created_at"]
            ],
            [
              "field",
              {
                "base-type"      = "type/DateTime"
                "effective-type" = "type/DateTime"
                "lib/uuid"       = "c01bc183-c86d-47bc-9a5c-8729510e5054"
              },
              metabase_table.accounts.fields["last_login_at"]
            ]
          ]
          filters = [
            [
              "=",
              {
                "lib/uuid" = "dc51909e-ef91-4bc8-87ab-2ab52efce2b2"
              },
              [
                "field",
                {
                  "base-type"      = "type/Text"
                  "effective-type" = "type/Text"
                  "lib/uuid"       = "39da019b-3efa-43d6-bf31-52d851482b38"
                },
                metabase_table.accounts.fields["status"]
              ],
              "active"
            ],
            [
              "is-null",
              {
                "lib/uuid" = "b662d426-6e42-4a6d-ab22-f947ef6da1e8"
              },
              [
                "field",
                {
                  "base-type"      = "type/DateTime"
                  "effective-type" = "type/DateTime"
                  "lib/uuid"       = "085b10d2-f33f-4c8a-9500-6c1e6f9400f2"
                },
                metabase_table.accounts.fields["disabled_at"]
              ]
            ],
            [
              "not-null",
              {
                "lib/uuid" = "a354bf6d-fdf1-44f3-9340-87fc97b825a1"
              },
              [
                "field",
                {
                  "base-type"      = "type/DateTime"
                  "effective-type" = "type/DateTime"
                  "lib/uuid"       = "729ab69d-d9a7-4fe5-bc6b-25fc9f1b22c0"
                },
                metabase_table.accounts.fields["last_login_at"]
              ]
            ],
            [
              "<",
              {
                "lib/uuid" = "b37a64f2-54f2-4f4f-a7ec-852fdcfb7d2c"
              },
              [
                "field",
                {
                  "base-type"      = "type/DateTime"
                  "effective-type" = "type/DateTime"
                  "lib/uuid"       = "89987b7f-1ffe-4db9-a5e8-45bf7e62172f"
                },
                metabase_table.accounts.fields["last_login_at"]
              ],
              # Metabase injects a lib/uuid into this expression; keep it here to avoid provider drift on apply.
              [
                "relative-datetime",
                {
                  "lib/uuid" = "6d9d229f-9e82-4b40-b50b-08c27e953db3"
                },
                -7,
                "day"
              ]
            ]
          ]
          "order-by" = [
            [
              "asc",
              {
                "lib/uuid" = "73891154-9e22-4c08-bf34-cbeca75904d3"
              },
              [
                "field",
                {
                  "base-type"      = "type/DateTime"
                  "effective-type" = "type/DateTime"
                  "lib/uuid"       = "5c3d8dd4-fd6c-44ef-a374-884e48e6b168"
                },
                metabase_table.accounts.fields["last_login_at"]
              ]
            ],
            [
              "asc",
              {
                "lib/uuid" = "0cf79b07-44fb-4e7e-be18-5a652b1657d0"
              },
              [
                "field",
                {
                  "base-type"      = "type/Text"
                  "effective-type" = "type/Text"
                  "lib/uuid"       = "ad1920fa-7f5d-4ba4-9b04-2a1218cd319b"
                },
                metabase_table.accounts.fields["username"]
              ]
            ]
          ]
        }
      ]
    }
  })
}

# ---------------------------
# Card: Stale Active Accounts Count
# ---------------------------
resource "metabase_card" "stale_active_accounts_count" {
  json = jsonencode({
    name                   = "Stale Active Accounts"
    display                = "scalar"
    description            = "Count of active accounts whose last login is older than 7 days."
    cache_ttl              = null
    collection_id          = null
    collection_position    = null
    query_type             = "query"
    parameters             = []
    parameter_mappings     = []
    visualization_settings = {}
    dataset_query = {
      database   = metabase_database.postgres.id
      "lib/type" = "mbql/query"
      stages = [
        {
          "lib/type"     = "mbql.stage/mbql"
          "source-table" = metabase_table.accounts.id
          aggregation = [
            [
              "count",
              {
                "lib/uuid" = "9430b6da-1c9f-4c7d-8f3b-4d0d84df1d4f"
              }
            ]
          ]
          filters = [
            [
              "=",
              {
                "lib/uuid" = "f289a566-6841-4201-8a64-b0cb7b0d4d19"
              },
              [
                "field",
                {
                  "base-type"      = "type/Text"
                  "effective-type" = "type/Text"
                  "lib/uuid"       = "ed4bd65c-b8a1-48f6-bb90-b8d361b22070"
                },
                metabase_table.accounts.fields["status"]
              ],
              "active"
            ],
            [
              "is-null",
              {
                "lib/uuid" = "a5d00a71-ebd6-4bf8-a554-929621fcb63d"
              },
              [
                "field",
                {
                  "base-type"      = "type/DateTime"
                  "effective-type" = "type/DateTime"
                  "lib/uuid"       = "1f64196b-e146-46b7-bfe4-24d3fd5e5b24"
                },
                metabase_table.accounts.fields["disabled_at"]
              ]
            ],
            [
              "not-null",
              {
                "lib/uuid" = "2d0c25f5-d0fc-45bb-a3ce-87f2d5bf4f05"
              },
              [
                "field",
                {
                  "base-type"      = "type/DateTime"
                  "effective-type" = "type/DateTime"
                  "lib/uuid"       = "f9d49ef8-cf4d-483d-a875-8d625e6d011e"
                },
                metabase_table.accounts.fields["last_login_at"]
              ]
            ],
            [
              "<",
              {
                "lib/uuid" = "0d7e1f90-3dca-4353-b7db-29033d4b7304"
              },
              [
                "field",
                {
                  "base-type"      = "type/DateTime"
                  "effective-type" = "type/DateTime"
                  "lib/uuid"       = "00252ea7-fb5f-4084-8b39-ea50beec5964"
                },
                metabase_table.accounts.fields["last_login_at"]
              ],
              [
                "relative-datetime",
                {
                  "lib/uuid" = "8a151413-0d56-42a4-a120-34f6a0caf64c"
                },
                -7,
                "day"
              ]
            ]
          ]
        }
      ]
    }
  })
}

# ---------------------------
# Card: Orphan Accounts
# ---------------------------
resource "metabase_card" "orphan_accounts_count" {
  json = jsonencode({
    name                   = "Orphan Accounts"
    display                = "scalar"
    description            = "Count of active accounts that are not linked to an identity."
    cache_ttl              = null
    collection_id          = null
    collection_position    = null
    query_type             = "query"
    parameters             = []
    parameter_mappings     = []
    visualization_settings = {}
    dataset_query = {
      database   = metabase_database.postgres.id
      "lib/type" = "mbql/query"
      stages = [
        {
          "lib/type"     = "mbql.stage/mbql"
          "source-table" = metabase_table.orphaned_accounts.id
          aggregation = [
            [
              "count",
              {
                "lib/uuid" = "a73c87d2-8bf1-4d1a-a2c6-76522132d1c5"
              }
            ]
          ]
        }
      ]
    }
  })
}

# ---------------------------
# Card: Entitlement Relationships
# ---------------------------
resource "metabase_card" "entitlement_relationships" {
  json = jsonencode({
    name                   = "Entitlement Relationships"
    display                = "table"
    description            = "Entitlement-to-entitlement relationships with relation source and parent/child source discriminators."
    cache_ttl              = null
    collection_id          = null
    collection_position    = null
    query_type             = "query"
    parameters             = []
    parameter_mappings     = []
    visualization_settings = {}
    dataset_query = {
      database   = metabase_database.postgres.id
      "lib/type" = "mbql/query"
      stages = [
        {
          "lib/type"     = "mbql.stage/mbql"
          "source-table" = metabase_table.entitlement_relations.id
          fields = [
            [
              "field",
              {
                "base-type"      = "type/Text"
                "effective-type" = "type/Text"
                "lib/uuid"       = "d2f0b963-6612-475d-a7e3-6fe8745476a5"
              },
              metabase_table.entitlement_relations.fields["source"]
            ],
            [
              "field",
              {
                "base-type"      = "type/Text"
                "effective-type" = "type/Text"
                "join-alias"     = "Parent Entitlement"
                "lib/uuid"       = "af792e75-74ef-48c0-b502-d885dc647a09"
              },
              metabase_table.entitlements.fields["display_name"]
            ],
            [
              "field",
              {
                "base-type"      = "type/Text"
                "effective-type" = "type/Text"
                "join-alias"     = "Parent Entitlement"
                "lib/uuid"       = "12fd47ee-96f2-41f5-b4e7-b7dcf584a0a1"
              },
              metabase_table.entitlements.fields["kind"]
            ],
            [
              "field",
              {
                "base-type"      = "type/Text"
                "effective-type" = "type/Text"
                "join-alias"     = "Child Entitlement"
                "lib/uuid"       = "ce80428d-9a43-42bc-aa31-dfd9a46269a4"
              },
              metabase_table.entitlements.fields["display_name"]
            ],
            [
              "field",
              {
                "base-type"      = "type/Text"
                "effective-type" = "type/Text"
                "join-alias"     = "Child Entitlement"
                "lib/uuid"       = "8ca0f0f8-4a82-40f5-ae9e-b7c52d1ff57f"
              },
              metabase_table.entitlements.fields["kind"]
            ]
          ]
          joins = [
            {
              "lib/type" = "mbql/join"
              alias      = "Parent Entitlement"
              fields     = "none"
              conditions = [
                [
                  "=",
                  {
                    "lib/uuid" = "2f401ef4-2a5d-4f80-974f-70553a210072"
                  },
                  [
                    "field",
                    {
                      "base-type"      = "type/Text"
                      "effective-type" = "type/Text"
                      "lib/uuid"       = "4ca02c2a-d1ec-4ed0-a6cb-6a807afc0ff7"
                    },
                    metabase_table.entitlement_relations.fields["parent_entitlement_id"]
                  ],
                  [
                    "field",
                    {
                      "base-type"      = "type/Text"
                      "effective-type" = "type/Text"
                      "join-alias"     = "Parent Entitlement"
                      "lib/uuid"       = "7f7cefe4-f5bf-4c0e-a298-7459389f9a53"
                    },
                    metabase_table.entitlements.fields["entitlement_id"]
                  ]
                ]
              ]
              stages = [
                {
                  "lib/type"     = "mbql.stage/mbql"
                  "source-table" = metabase_table.entitlements.id
                }
              ]
              "lib/options" = {
                "lib/uuid" = "bf29afc4-53b1-4bc5-8f7a-5b84fdbca54d"
              }
            },
            {
              "lib/type" = "mbql/join"
              alias      = "Child Entitlement"
              fields     = "none"
              conditions = [
                [
                  "=",
                  {
                    "lib/uuid" = "5cfefdd4-c376-48ab-9d1f-95de9f07a662"
                  },
                  [
                    "field",
                    {
                      "base-type"      = "type/Text"
                      "effective-type" = "type/Text"
                      "lib/uuid"       = "73a16e22-0f3b-43a2-a20f-c68f76106e98"
                    },
                    metabase_table.entitlement_relations.fields["child_entitlement_id"]
                  ],
                  [
                    "field",
                    {
                      "base-type"      = "type/Text"
                      "effective-type" = "type/Text"
                      "join-alias"     = "Child Entitlement"
                      "lib/uuid"       = "4788c46a-565c-4f84-b89c-8f1c644d2f4a"
                    },
                    metabase_table.entitlements.fields["entitlement_id"]
                  ]
                ]
              ]
              stages = [
                {
                  "lib/type"     = "mbql.stage/mbql"
                  "source-table" = metabase_table.entitlements.id
                }
              ]
              "lib/options" = {
                "lib/uuid" = "97e09577-83d6-4e5b-9f5e-6b5e7fcc4e80"
              }
            }
          ]
          "order-by" = [
            [
              "asc",
              {
                "lib/uuid" = "e11bc46b-1817-4fb7-a85c-723e0136bf34"
              },
              [
                "field",
                {
                  "base-type"      = "type/Text"
                  "effective-type" = "type/Text"
                  "lib/uuid"       = "4fe46f8f-9ba0-455e-bd97-48d7fd434746"
                },
                metabase_table.entitlement_relations.fields["source"]
              ]
            ],
            [
              "asc",
              {
                "lib/uuid" = "f3506176-e22d-4479-b365-e4d51d7cc9be"
              },
              [
                "field",
                {
                  "base-type"      = "type/Text"
                  "effective-type" = "type/Text"
                  "join-alias"     = "Parent Entitlement"
                  "lib/uuid"       = "443810bc-f7fc-4e39-9fd5-348a7d27057e"
                },
                metabase_table.entitlements.fields["display_name"]
              ]
            ],
            [
              "asc",
              {
                "lib/uuid" = "f1aef34f-7ad1-4a7e-a0e2-2db68e3ab3ee"
              },
              [
                "field",
                {
                  "base-type"      = "type/Text"
                  "effective-type" = "type/Text"
                  "join-alias"     = "Child Entitlement"
                  "lib/uuid"       = "83c43e20-f28f-4854-bf77-ce307ccfe925"
                },
                metabase_table.entitlements.fields["display_name"]
              ]
            ]
          ]
        }
      ]
    }
  })
}

# ---------------------------
# Card: Identity Summary At Time
# ---------------------------
resource "metabase_card" "identity_summary_at_time" {
  json = jsonencode({
    name                   = "Identity Summary At Time"
    display                = "table"
    description            = "One-row identity context for the selected identity and snapshot date. Use this above the entitlement detail table during investigations."
    cache_ttl              = null
    collection_id          = null
    collection_position    = null
    query_type             = "native"
    parameters             = []
    parameter_mappings     = []
    visualization_settings = {}
    dataset_query = {
      database   = metabase_database.postgres.id
      "lib/type" = "mbql/query"
      stages = [
        {
          "lib/type" = "mbql.stage/native"
          native     = <<-SQL
            SELECT DISTINCT
              identity_id,
              display_name,
              email,
              employment_status,
              department,
              org_unit_id,
              org_unit_name,
              org_unit_path,
              org_unit_type
            FROM audit.get_identity_access_snapshot(
              {{identity_email}},
              LEAST({{snapshot_timestamp}}::date, CURRENT_DATE - 1) + INTERVAL '1 day' - INTERVAL '1 second'
            )
            LIMIT 1
          SQL
          "template-tags" = {
            identity_email = {
              id             = "98d98f84-9185-4eb4-85e1-b9171c01439f"
              name           = "identity_email"
              "display-name" = "Identity Email"
              type           = "text"
              required       = true
            }
            snapshot_timestamp = {
              id             = "fe198fdf-e5d8-45e2-a151-3984d87556cd"
              name           = "snapshot_timestamp"
              "display-name" = "Snapshot Date"
              type           = "date"
              required       = true
            }
          }
        }
      ]
    }
  })
}

# ---------------------------
# Card: Identity Access At Time
# ---------------------------
resource "metabase_card" "identity_access_at_time" {
  json = jsonencode({
    name                   = "Identity Entitlements At Time"
    display                = "table"
    description            = "One row per entitlement for the selected identity as of the end of the selected day. Use the summary card above for identity context."
    cache_ttl              = null
    collection_id          = null
    collection_position    = null
    query_type             = "native"
    parameters             = []
    parameter_mappings     = []
    visualization_settings = {}
    dataset_query = {
      database   = metabase_database.postgres.id
      "lib/type" = "mbql/query"
      stages = [
        {
          "lib/type" = "mbql.stage/native"
          native     = <<-SQL
            SELECT
              app_name,
              entitlement_name,
              entitlement_type,
              via_account,
              via_source,
              access_granted_date
            FROM audit.get_identity_access_snapshot(
              {{identity_email}},
              LEAST({{snapshot_timestamp}}::date, CURRENT_DATE - 1) + INTERVAL '1 day' - INTERVAL '1 second'
            )
            ORDER BY
              COALESCE(app_name, ''),
              entitlement_name,
              via_source,
              via_account
          SQL
          "template-tags" = {
            identity_email = {
              id             = "3d277ba4-6c11-4d7c-90a1-2ea1efe8f901"
              name           = "identity_email"
              "display-name" = "Identity Email"
              type           = "text"
              required       = true
            }
            snapshot_timestamp = {
              id             = "ce4bd2a6-8e17-4bb6-b50d-252dfd5bfa5c"
              name           = "snapshot_timestamp"
              "display-name" = "Snapshot Date"
              type           = "date"
              required       = true
            }
          }
        }
      ]
    }
  })
}

# ---------------------------
# Card: Account Access At Time
# ---------------------------
resource "metabase_card" "account_access_at_time" {
  json = jsonencode({
    name                   = "Account Access At Time"
    display                = "table"
    description            = "Investigation question for an account access snapshot as of the end of a selected day. Pick a date in the dashboard filter and Metabase will evaluate access at 23:59:59 for that day."
    cache_ttl              = null
    collection_id          = null
    collection_position    = null
    query_type             = "native"
    parameters             = []
    parameter_mappings     = []
    visualization_settings = {}
    dataset_query = {
      database   = metabase_database.postgres.id
      "lib/type" = "mbql/query"
      stages = [
        {
          "lib/type" = "mbql.stage/native"
          native     = <<-SQL
            SELECT
              account_id,
              username,
              source,
              account_status,
              identity_id,
              display_name,
              email,
              app_name,
              app_mapping_source,
              entitlement_name,
              entitlement_type,
              entitlement_source,
              access_granted_date
            FROM audit.get_account_access_snapshot(
              {{account_source}},
              {{account_username}},
              LEAST({{snapshot_timestamp}}::date, CURRENT_DATE - 1) + INTERVAL '1 day' - INTERVAL '1 second'
            )
            ORDER BY
              COALESCE(app_name, ''),
              entitlement_name,
              entitlement_source,
              username
          SQL
          "template-tags" = {
            account_source = {
              id             = "154ab4db-f7ec-41ce-b2ee-c37bc6bc5c1b"
              name           = "account_source"
              "display-name" = "Account Source"
              type           = "text"
              required       = true
            }
            account_username = {
              id             = "0283e122-a447-440e-a4c6-7c9ae76f3fc1"
              name           = "account_username"
              "display-name" = "Account Username"
              type           = "text"
              required       = true
            }
            snapshot_timestamp = {
              id             = "e2b50f98-4098-4cf9-a245-7fed49956b51"
              name           = "snapshot_timestamp"
              "display-name" = "Snapshot Date"
              type           = "date"
              required       = true
            }
          }
        }
      ]
    }
  })
}

# ---------------------------
# Card: Account Entitlement Relationships
# ---------------------------
resource "metabase_card" "account_entitlement_relationships" {
  json = jsonencode({
    name                   = "Accounts to Entitlements"
    display                = "table"
    description            = "Built with the Metabase query builder using bi_views.identity_entitlements as the base relationship view."
    cache_ttl              = null
    collection_id          = null
    collection_position    = null
    query_type             = "query"
    parameters             = []
    parameter_mappings     = []
    visualization_settings = {}
    dataset_query = {
      database   = metabase_database.postgres.id
      "lib/type" = "mbql/query"
      stages = [
        {
          "lib/type"     = "mbql.stage/mbql"
          "source-table" = metabase_table.identity_entitlements.id
          fields = [
            [
              "field",
              {
                "base-type"      = "type/Text"
                "effective-type" = "type/Text"
                "lib/uuid"       = "ba50d423-c6f8-4313-bd45-523b580864a6"
              },
              metabase_table.identity_entitlements.fields["assigned_via_source"]
            ],
            [
              "field",
              {
                "base-type"      = "type/Text"
                "effective-type" = "type/Text"
                "join-alias"     = "Accounts"
                "lib/uuid"       = "99416c93-26d6-45fd-a10d-7273c0f5f00d"
              },
              metabase_table.accounts.fields["username"]
            ],
            [
              "field",
              {
                "base-type"      = "type/Text"
                "effective-type" = "type/Text"
                "join-alias"     = "Entitlements"
                "lib/uuid"       = "6f10eb0a-8f3f-4bc0-b2df-1698b58bd3fe"
              },
              metabase_table.entitlements.fields["kind"]
            ],
            [
              "field",
              {
                "base-type"      = "type/Text"
                "effective-type" = "type/Text"
                "join-alias"     = "Entitlements"
                "lib/uuid"       = "51683f16-0dd8-4494-9865-ec9e733bf352"
              },
              metabase_table.entitlements.fields["name"]
            ],
            [
              "field",
              {
                "base-type"      = "type/Text"
                "effective-type" = "type/Text"
                "join-alias"     = "Accounts"
                "lib/uuid"       = "97567598-5244-4de0-9fba-a0f82c314486"
              },
              metabase_table.accounts.fields["created_at"]
            ],
            [
              "field",
              {
                "base-type"      = "type/Text"
                "effective-type" = "type/Text"
                "join-alias"     = "Accounts"
                "lib/uuid"       = "0cfc87ca-b69d-43c2-a8aa-643ff88a0e71"
              },
              metabase_table.accounts.fields["attributes → display_name"]
            ],
            [
              "field",
              {
                "base-type"      = "type/Text"
                "effective-type" = "type/Text"
                "lib/uuid"       = "bfc6252c-d4cf-46cc-b38d-03fc0f11150a"
              },
              metabase_table.identity_entitlements.fields["display_name"]
            ],
            [
              "field",
              {
                "base-type"      = "type/Text"
                "effective-type" = "type/Text"
                "join-alias"     = "Accounts"
                "lib/uuid"       = "0d1c2a64-b4a1-47e0-bf55-edf77eb0ed11"
              },
              metabase_table.accounts.fields["status"]
            ],
            [
              "field",
              {
                "base-type"      = "type/Text"
                "effective-type" = "type/Text"
                "join-alias"     = "Entitlements"
                "lib/uuid"       = "f503fc6d-8848-46f2-9ac9-a7da7f65055a"
              },
              metabase_table.entitlements.fields["description"]
            ]
          ]
          joins = [
            {
              "lib/type" = "mbql/join"
              alias      = "Accounts"
              fields     = "all"
              conditions = [
                [
                  "=",
                  {
                    "lib/uuid" = "0d2dadc2-96f6-4e4d-80f8-455edc5cc758"
                  },
                  [
                    "field",
                    {
                      "base-type"      = "type/Text"
                      "effective-type" = "type/Text"
                      "lib/uuid"       = "32e3fded-4df4-41a8-b7fb-f0fe4f6eaadc"
                    },
                    metabase_table.identity_entitlements.fields["assigned_via_account"]
                  ],
                  [
                    "field",
                    {
                      "base-type"      = "type/Text"
                      "effective-type" = "type/Text"
                      "join-alias"     = "Accounts"
                      "lib/uuid"       = "7d4472ae-fdb7-416f-b68e-e1891b3fbcad"
                    },
                    metabase_table.accounts.fields["username"]
                  ]
                ],
                [
                  "=",
                  {
                    "lib/uuid" = "3c20dcb6-a3f9-4fe6-85bc-6a32c20b7cd2"
                  },
                  [
                    "field",
                    {
                      "base-type"      = "type/Text"
                      "effective-type" = "type/Text"
                      "lib/uuid"       = "638456e3-c38e-42f0-bcba-85d4e182ca06"
                    },
                    metabase_table.identity_entitlements.fields["assigned_via_source"]
                  ],
                  [
                    "field",
                    {
                      "base-type"      = "type/Text"
                      "effective-type" = "type/Text"
                      "join-alias"     = "Accounts"
                      "lib/uuid"       = "d7d3ff70-b760-4533-b6dc-987cbcb6c694"
                    },
                    metabase_table.accounts.fields["source"]
                  ]
                ]
              ]
              stages = [
                {
                  "lib/type"     = "mbql.stage/mbql"
                  "source-table" = metabase_table.accounts.id
                }
              ]
              "lib/options" = {
                "lib/uuid" = "3ffec97f-2bb4-40ee-9170-f6c8d4746fb5"
              }
            },
            {
              "lib/type" = "mbql/join"
              alias      = "Entitlements"
              fields     = "all"
              conditions = [
                [
                  "=",
                  {
                    "lib/uuid" = "198f9b5e-d3e0-4d3f-8634-5ab8c4be00d2"
                  },
                  [
                    "field",
                    {
                      "base-type"      = "type/Text"
                      "effective-type" = "type/Text"
                      "lib/uuid"       = "6f3ca544-cd8a-4cc2-8ee5-64b8e6668e25"
                    },
                    metabase_table.identity_entitlements.fields["entitlement_id"]
                  ],
                  [
                    "field",
                    {
                      "base-type"      = "type/Text"
                      "effective-type" = "type/Text"
                      "join-alias"     = "Entitlements"
                      "lib/uuid"       = "4d889d38-43fb-433c-ab57-f95e76cf0ca9"
                    },
                    metabase_table.entitlements.fields["entitlement_id"]
                  ]
                ],
                [
                  "=",
                  {
                    "lib/uuid" = "1dbf8b31-197b-4ae5-9313-9c61dc3801fc"
                  },
                  [
                    "field",
                    {
                      "base-type"      = "type/Text"
                      "effective-type" = "type/Text"
                      "lib/uuid"       = "f4573d76-379f-492b-a0bd-9b8806e3f438"
                    },
                    metabase_table.identity_entitlements.fields["entitlement_source"]
                  ],
                  [
                    "field",
                    {
                      "base-type"      = "type/Text"
                      "effective-type" = "type/Text"
                      "join-alias"     = "Entitlements"
                      "lib/uuid"       = "4b87bafe-d8d8-4d00-b333-c3658fa6f6e1"
                    },
                    metabase_table.entitlements.fields["source"]
                  ]
                ]
              ]
              stages = [
                {
                  "lib/type"     = "mbql.stage/mbql"
                  "source-table" = metabase_table.entitlements.id
                }
              ]
              "lib/options" = {
                "lib/uuid" = "85c9d926-fc51-4ca4-b4c6-e9256f251fec"
              }
            }
          ]
          "order-by" = [
            [
              "asc",
              {
                "lib/uuid" = "8f1f27c7-4577-4b43-b1f4-c208947ef1de"
              },
              [
                "field",
                {
                  "base-type"      = "type/Text"
                  "effective-type" = "type/Text"
                  "join-alias"     = "Accounts"
                  "lib/uuid"       = "7d184b7c-2d99-47a8-a26e-83152af6a477"
                },
                metabase_table.accounts.fields["username"]
              ]
            ],
            [
              "asc",
              {
                "lib/uuid" = "5346b3e9-cd1b-4e10-8416-5d29608563bd"
              },
              [
                "field",
                {
                  "base-type"      = "type/Text"
                  "effective-type" = "type/Text"
                  "join-alias"     = "Entitlements"
                  "lib/uuid"       = "1fce8fa7-a5cc-467f-a7b1-2d0271b03ad9"
                },
                metabase_table.entitlements.fields["name"]
              ]
            ]
          ]
        }
      ]
    }
  })
}

# ---------------------------
# Card: Affected Identities (Latest Snapshot)
# ---------------------------
resource "metabase_card" "crossid_affected_identities_latest" {
  json = jsonencode({
    name                   = "Affected Identities (Latest Snapshot)"
    display                = "scalar"
    description            = "Count of identities with access outside Crossid policy in the latest daily snapshot. Crossid source rows are excluded by the analytics views."
    cache_ttl              = null
    collection_id          = null
    collection_position    = null
    query_type             = "native"
    parameters             = []
    parameter_mappings     = []
    visualization_settings = {}
    dataset_query = {
      database   = metabase_database.postgres.id
      "lib/type" = "mbql/query"
      stages = [
        {
          "lib/type" = "mbql.stage/native"
          native     = <<-SQL
            WITH latest AS (
              SELECT MAX(snapshot_date) AS snapshot_date
              FROM analytics.crossid_unapproved_entitlements_daily
            )
            SELECT COUNT(DISTINCT d.identity_id) AS affected_identities
            FROM analytics.crossid_unapproved_entitlements_daily d
            JOIN latest l USING (snapshot_date)
          SQL
        }
      ]
    }
  })
}

# ---------------------------
# Card: Unapproved Entitlements (Latest Snapshot)
# ---------------------------
resource "metabase_card" "crossid_unapproved_entitlements_latest" {
  json = jsonencode({
    name                   = "Unapproved Entitlements (Latest Snapshot)"
    display                = "scalar"
    description            = "Count of granted entitlements not covered by Crossid wanted-state policy in the latest daily snapshot."
    cache_ttl              = null
    collection_id          = null
    collection_position    = null
    query_type             = "native"
    parameters             = []
    parameter_mappings     = []
    visualization_settings = {}
    dataset_query = {
      database   = metabase_database.postgres.id
      "lib/type" = "mbql/query"
      stages = [
        {
          "lib/type" = "mbql.stage/native"
          native     = <<-SQL
            WITH latest AS (
              SELECT MAX(snapshot_date) AS snapshot_date
              FROM analytics.crossid_unapproved_entitlements_daily
            )
            SELECT COUNT(*) AS unapproved_entitlements
            FROM analytics.crossid_unapproved_entitlements_daily d
            JOIN latest l USING (snapshot_date)
          SQL
        }
      ]
    }
  })
}

# ---------------------------
# Card: Latest Unapproved Access by Source
# ---------------------------
resource "metabase_card" "crossid_unapproved_by_source_latest" {
  json = jsonencode({
    name                   = "Latest Unapproved Access by Source"
    display                = "table"
    description            = "Latest daily snapshot broken out by downstream source system so users can see where access outside Crossid policy is concentrated."
    cache_ttl              = null
    collection_id          = null
    collection_position    = null
    query_type             = "native"
    parameters             = []
    parameter_mappings     = []
    visualization_settings = {}
    dataset_query = {
      database   = metabase_database.postgres.id
      "lib/type" = "mbql/query"
      stages = [
        {
          "lib/type" = "mbql.stage/native"
          native     = <<-SQL
            WITH latest AS (
              SELECT MAX(snapshot_date) AS snapshot_date
              FROM analytics.crossid_unapproved_entitlements_daily
            )
            SELECT
              d.source,
              COUNT(*) AS unapproved_entitlement_count,
              COUNT(DISTINCT d.identity_id) AS affected_identity_count,
              COUNT(DISTINCT d.account_id) AS affected_account_count
            FROM analytics.crossid_unapproved_entitlements_daily d
            JOIN latest l USING (snapshot_date)
            GROUP BY d.source
            ORDER BY unapproved_entitlement_count DESC, d.source
          SQL
        }
      ]
    }
  })
}

# ---------------------------
# Card: Identities with Unapproved Access
# ---------------------------
resource "metabase_card" "crossid_unapproved_identities_latest" {
  json = jsonencode({
    name                = "Primary Drivers: Identities with Unapproved Access"
    display             = "table"
    description         = "Primary triage list for operators and reviewers. One row per identity in the latest daily snapshot, sorted by the highest unapproved entitlement count first."
    cache_ttl           = null
    collection_id       = null
    collection_position = null
    query_type          = "native"
    parameters          = []
    parameter_mappings  = []
    visualization_settings = {
      column_settings = {
        (jsonencode(["name", "display_name"])) = {
          column_title = "Name"
        }
        (jsonencode(["name", "email"])) = {
          column_title = "Email"
        }
        (jsonencode(["name", "department"])) = {
          column_title = "Department"
        }
        (jsonencode(["name", "unapproved_entitlement_count"])) = {
          column_title = "Unapproved Count"
        }
        (jsonencode(["name", "affected_account_count"])) = {
          column_title = "Affected Accounts"
        }
        (jsonencode(["name", "affected_sources"])) = {
          column_title = "Affected Sources"
        }
      }
    }
    dataset_query = {
      database   = metabase_database.postgres.id
      "lib/type" = "mbql/query"
      stages = [
        {
          "lib/type" = "mbql.stage/native"
          native     = <<-SQL
            WITH latest AS (
              SELECT MAX(snapshot_date) AS snapshot_date
              FROM analytics.crossid_unapproved_entitlements_daily
            )
            SELECT
              COALESCE(i.display_name, d.identity_id) AS display_name,
              COALESCE(i.email, d.identity_id) AS email,
              COALESCE(i.department, 'Unknown') AS department,
              COUNT(*) AS unapproved_entitlement_count,
              COUNT(DISTINCT d.account_id) AS affected_account_count,
              STRING_AGG(DISTINCT d.source, ', ' ORDER BY d.source) AS affected_sources
            FROM analytics.crossid_unapproved_entitlements_daily d
            JOIN latest l USING (snapshot_date)
            LEFT JOIN bi_views.active_identities i
              ON i.identity_id = d.identity_id
            GROUP BY
              COALESCE(i.display_name, d.identity_id),
              COALESCE(i.email, d.identity_id),
              COALESCE(i.department, 'Unknown')
            ORDER BY unapproved_entitlement_count DESC, display_name
          SQL
        }
      ]
    }
  })
}

# ---------------------------
# Card: Granted vs Unapproved Over Time
# ---------------------------
resource "metabase_card" "crossid_granted_vs_unapproved_over_time" {
  json = jsonencode({
    name                = "Granted vs Unapproved Entitlements Over Time"
    display             = "line"
    description         = "Daily trend comparing total granted entitlements against the subset that is outside Crossid policy."
    cache_ttl           = null
    collection_id       = null
    collection_position = null
    query_type          = "native"
    parameters          = []
    parameter_mappings  = []
    visualization_settings = {
      "graph.y_axis.unpin_from_zero" : true
    }
    dataset_query = {
      database   = metabase_database.postgres.id
      "lib/type" = "mbql/query"
      stages = [
        {
          "lib/type" = "mbql.stage/native"
          native     = <<-SQL
            WITH granted AS (
              SELECT snapshot_date, COUNT(*)::bigint AS entitlement_count
              FROM analytics.crossid_actual_entitlements_daily
              GROUP BY snapshot_date
            ),
            unapproved AS (
              SELECT snapshot_date, SUM(unapproved_entitlement_count)::bigint AS entitlement_count
              FROM analytics.crossid_unapproved_entitlements_timeseries
              GROUP BY snapshot_date
            )
            SELECT snapshot_date, series, entitlement_count
            FROM (
              SELECT snapshot_date, 'Granted entitlements' AS series, entitlement_count
              FROM granted
              UNION ALL
              SELECT snapshot_date, 'Unapproved entitlements' AS series, entitlement_count
              FROM unapproved
            ) AS combined
            ORDER BY snapshot_date, series
          SQL
        }
      ]
    }
  })
}

# ---------------------------
# Card: Unapproved Access Rate Over Time
# ---------------------------
resource "metabase_card" "crossid_unapproved_rate_over_time" {
  json = jsonencode({
    name                = "Unapproved Access Rate Over Time"
    display             = "line"
    description         = "Daily percentage of granted entitlements that are outside Crossid policy. This is the clearest trend signal as total access volume changes."
    cache_ttl           = null
    collection_id       = null
    collection_position = null
    query_type          = "native"
    parameters          = []
    parameter_mappings  = []
    visualization_settings = {
      column_settings = {
        (jsonencode(["name", "unapproved_access_rate"])) = {
          number_style = "percent"
          decimals     = 2
        }
      }
    }
    dataset_query = {
      database   = metabase_database.postgres.id
      "lib/type" = "mbql/query"
      stages = [
        {
          "lib/type" = "mbql.stage/native"
          native     = <<-SQL
            WITH granted AS (
              SELECT snapshot_date, COUNT(*)::numeric AS granted_entitlement_count
              FROM analytics.crossid_actual_entitlements_daily
              GROUP BY snapshot_date
            ),
            unapproved AS (
              SELECT snapshot_date, SUM(unapproved_entitlement_count)::numeric AS unapproved_entitlement_count
              FROM analytics.crossid_unapproved_entitlements_timeseries
              GROUP BY snapshot_date
            )
            SELECT
              g.snapshot_date,
              ROUND(COALESCE(u.unapproved_entitlement_count, 0) / NULLIF(g.granted_entitlement_count, 0), 4) AS unapproved_access_rate
            FROM granted g
            LEFT JOIN unapproved u USING (snapshot_date)
            ORDER BY g.snapshot_date
          SQL
        }
      ]
    }
  })
}

# ---------------------------
# Card: Unapproved Entitlements by Source Over Time
# ---------------------------
resource "metabase_card" "crossid_unapproved_by_source_over_time" {
  json = jsonencode({
    name                   = "Unapproved Entitlements by Source Over Time"
    display                = "line"
    description            = "Daily trend of granted entitlements outside Crossid policy, broken out by downstream source system."
    cache_ttl              = null
    collection_id          = null
    collection_position    = null
    query_type             = "native"
    parameters             = []
    parameter_mappings     = []
    visualization_settings = {}
    dataset_query = {
      database   = metabase_database.postgres.id
      "lib/type" = "mbql/query"
      stages = [
        {
          "lib/type" = "mbql.stage/native"
          native     = <<-SQL
            SELECT
              snapshot_date,
              source,
              unapproved_entitlement_count
            FROM analytics.crossid_unapproved_entitlements_timeseries
            ORDER BY snapshot_date, source
          SQL
        }
      ]
    }
  })
}

# ---------------------------
# Card: Common Entitlements Across Identities
# ---------------------------
resource "metabase_card" "common_entitlements" {
  json = jsonencode({
    name                   = "Common Entitlements Across Identities"
    display                = "table"
    description            = "Entitlements shared by every identity in the supplied comma-separated email list, as of today. Each row is broken out per source so the Source filter narrows results to a single source system."
    cache_ttl              = null
    collection_id          = null
    collection_position    = null
    query_type             = "native"
    parameters             = []
    parameter_mappings     = []
    visualization_settings = {}
    dataset_query = {
      database   = metabase_database.postgres.id
      "lib/type" = "mbql/query"
      stages = [
        {
          "lib/type" = "mbql.stage/native"
          native     = <<-SQL
            WITH emails AS (
              SELECT TRIM(unnested) AS email
              FROM UNNEST(STRING_TO_ARRAY({{identity_emails}}, ',')) AS unnested
              WHERE TRIM(unnested) <> ''
            ),
            email_count AS (SELECT COUNT(*) AS n FROM emails),
            all_access AS (
              SELECT
                e.email      AS identity_email,
                snap.entitlement_name,
                snap.entitlement_type,
                snap.app_name,
                snap.via_source
              FROM emails e
              CROSS JOIN LATERAL audit.get_identity_access_snapshot(
                e.email,
                CURRENT_DATE + INTERVAL '1 day' - INTERVAL '1 second'
              ) snap
            )
            SELECT
              app_name,
              entitlement_name,
              entitlement_type,
              via_source AS source
            FROM all_access
            WHERE TRUE
              [[AND via_source = {{source_filter}}]]
            GROUP BY app_name, entitlement_name, entitlement_type, via_source
            HAVING COUNT(DISTINCT identity_email) = (SELECT n FROM email_count)
            ORDER BY app_name, entitlement_name, via_source
          SQL
          "template-tags" = {
            identity_emails = {
              id             = "11111111-1111-4111-8111-111111111111"
              name           = "identity_emails"
              "display-name" = "Identity Emails (comma-separated)"
              type           = "text"
              required       = true
            }
            source_filter = {
              id             = "22222222-2222-4222-8222-222222222222"
              name           = "source_filter"
              "display-name" = "Source"
              type           = "text"
              required       = false
            }
          }
        }
      ]
    }
  })
}

# ---------------------------
# Card: Department Values (auxiliary — powers the Department dropdown in Who Works Here)
# ---------------------------
resource "metabase_card" "department_values" {
  json = jsonencode({
    name                   = "Department Values"
    display                = "table"
    description            = null
    cache_ttl              = null
    collection_id          = null
    collection_position    = null
    query_type             = "native"
    parameters             = []
    parameter_mappings     = []
    visualization_settings = {}
    dataset_query = {
      database   = metabase_database.postgres.id
      "lib/type" = "mbql/query"
      stages = [
        {
          "lib/type" = "mbql.stage/native"
          native     = "SELECT DISTINCT department FROM bi_views.active_identities WHERE department IS NOT NULL ORDER BY 1"
        }
      ]
    }
  })
}

# Card: Identity Email Values (auxiliary — powers the Identity Emails dropdown in Common Entitlements)
# ---------------------------
resource "metabase_card" "identity_email_values" {
  json = jsonencode({
    name                   = "Identity Email Values"
    display                = "table"
    description            = null
    cache_ttl              = null
    collection_id          = null
    collection_position    = null
    query_type             = "native"
    parameters             = []
    parameter_mappings     = []
    visualization_settings = {}
    dataset_query = {
      database   = metabase_database.postgres.id
      "lib/type" = "mbql/query"
      stages = [
        {
          "lib/type" = "mbql.stage/native"
          native     = "SELECT DISTINCT email FROM bi_views.active_identities WHERE email IS NOT NULL ORDER BY 1"
        }
      ]
    }
  })
}

# Card: Sensitivity Values (auxiliary — powers the Sensitivity dropdown in Entitlements Catalog)
# ---------------------------
# Card: Entitlements Catalog
# ---------------------------
resource "metabase_card" "entitlements_catalog" {
  json = jsonencode({
    name                   = "Entitlements Catalog"
    display                = "table"
    description            = "Full list of entitlements with description and sensitivity extracted from the attributes JSONB column. Use the Search filter to narrow by name or display name."
    cache_ttl              = null
    collection_id          = null
    collection_position    = null
    query_type             = "native"
    parameters             = []
    parameter_mappings     = []
    visualization_settings = {}
    dataset_query = {
      database   = metabase_database.postgres.id
      "lib/type" = "mbql/query"
      stages = [
        {
          "lib/type" = "mbql.stage/native"
          native     = <<-SQL
            SELECT
              source,
              kind,
              name          AS entitlement_name,
              display_name,
              attributes->>'description'           AS description,
              (attributes->'sensitivity')::int      AS sensitivity
            FROM bi_views.entitlements
            WHERE TRUE
              [[AND (
                name         ILIKE '%' || {{search}} || '%'
                OR display_name ILIKE '%' || {{search}} || '%'
              )]]
              [[AND (attributes->'sensitivity')::int >= {{sensitivity_min}}]]
              [[AND {{empty_sensitivity}} = 'yes' AND (attributes->'sensitivity') IS NULL]]
              [[AND source = {{source_filter_ec}}]]
            ORDER BY source, kind, name
          SQL
          "template-tags" = {
            search = {
              id             = "33333333-3333-4333-8333-333333333333"
              name           = "search"
              "display-name" = "Search"
              type           = "text"
              required       = false
            }
            sensitivity_min = {
              id             = "44444444-4444-4444-8444-444444444449"
              name           = "sensitivity_min"
              "display-name" = "Min Sensitivity (1–4)"
              type           = "number"
              required       = false
            }
            empty_sensitivity = {
              id             = "66666666-6666-4666-8666-666666666669"
              name           = "empty_sensitivity"
              "display-name" = "No Sensitivity Only"
              type           = "text"
              required       = false
            }
            source_filter_ec = {
              id             = "55555555-5555-4555-8555-555555555559"
              name           = "source_filter_ec"
              "display-name" = "Source"
              type           = "text"
              required       = false
            }
          }
        }
      ]
    }
  })
}

# ---------------------------
# Card: Identity Info (auxiliary — header card for Access Changes dashboard)
# ---------------------------
resource "metabase_card" "identity_info" {
  json = jsonencode({
    name                   = "Identity Info"
    display                = "table"
    description            = null
    cache_ttl              = null
    collection_id          = null
    collection_position    = null
    query_type             = "native"
    parameters             = []
    parameter_mappings     = []
    visualization_settings = {}
    dataset_query = {
      database   = metabase_database.postgres.id
      "lib/type" = "mbql/query"
      stages = [
        {
          "lib/type" = "mbql.stage/native"
          native     = <<-SQL
            SELECT display_name as Name, department, job_title as Title, manager_name as Manager
            FROM bi_views.active_identities
            WHERE email = {{identity_email}}
            LIMIT 1
          SQL
          "template-tags" = {
            identity_email = {
              id             = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
              name           = "identity_email"
              "display-name" = "Identity Email"
              type           = "text"
              required       = true
            }
          }
        }
      ]
    }
  })
}

# Card: Access Changes Added Count (auxiliary — header metric for Access Changes dashboard)
# ---------------------------
resource "metabase_card" "access_changes_added_count" {
  json = jsonencode({
    name                = "Entitlements Added"
    display             = "scalar"
    description         = null
    cache_ttl           = null
    collection_id       = null
    collection_position = null
    query_type          = "native"
    parameters          = []
    parameter_mappings  = []
    visualization_settings = {
      "scalar.field" = "added"
    }
    dataset_query = {
      database   = metabase_database.postgres.id
      "lib/type" = "mbql/query"
      stages = [
        {
          "lib/type" = "mbql.stage/native"
          native     = <<-SQL
            SELECT COUNT(*) AS added
            FROM audit.compare_access_between_dates(
              CAST({{start_date}} AS DATE),
              CAST({{end_date}} AS DATE) + INTERVAL '1 day' - INTERVAL '1 second'
            )
            WHERE change_type = 'ADDED'
              [[AND email = {{identity_email}}]]
          SQL
          "template-tags" = {
            start_date = {
              id             = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
              name           = "start_date"
              "display-name" = "Start Date"
              type           = "text"
              required       = true
            }
            end_date = {
              id             = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
              name           = "end_date"
              "display-name" = "End Date"
              type           = "text"
              required       = true
            }
            identity_email = {
              id             = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
              name           = "identity_email"
              "display-name" = "Identity Email"
              type           = "text"
              required       = false
            }
          }
        }
      ]
    }
  })
}

# Card: Access Changes Removed Count (auxiliary — header metric for Access Changes dashboard)
# ---------------------------
resource "metabase_card" "access_changes_removed_count" {
  json = jsonencode({
    name                = "Entitlements Removed"
    display             = "scalar"
    description         = null
    cache_ttl           = null
    collection_id       = null
    collection_position = null
    query_type          = "native"
    parameters          = []
    parameter_mappings  = []
    visualization_settings = {
      "scalar.field" = "removed"
    }
    dataset_query = {
      database   = metabase_database.postgres.id
      "lib/type" = "mbql/query"
      stages = [
        {
          "lib/type" = "mbql.stage/native"
          native     = <<-SQL
            SELECT COUNT(*) AS removed
            FROM audit.compare_access_between_dates(
              CAST({{start_date}} AS DATE),
              CAST({{end_date}} AS DATE) + INTERVAL '1 day' - INTERVAL '1 second'
            )
            WHERE change_type = 'REMOVED'
              [[AND email = {{identity_email}}]]
          SQL
          "template-tags" = {
            start_date = {
              id             = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
              name           = "start_date"
              "display-name" = "Start Date"
              type           = "text"
              required       = true
            }
            end_date = {
              id             = "ffffffff-ffff-4fff-8fff-ffffffffffff"
              name           = "end_date"
              "display-name" = "End Date"
              type           = "text"
              required       = true
            }
            identity_email = {
              id             = "00000000-0000-4000-8000-000000000001"
              name           = "identity_email"
              "display-name" = "Identity Email"
              type           = "text"
              required       = false
            }
          }
        }
      ]
    }
  })
}

# Card: Access Changes Between Dates
# ---------------------------
resource "metabase_card" "access_changes_between_dates" {
  json = jsonencode({
    name                = "Access Changes Between Dates"
    display             = "table"
    description         = "Entitlement changes (ADDED or REMOVED) between two dates for all identities. Filter optionally by identity email, source system, or change direction."
    cache_ttl           = null
    collection_id       = null
    collection_position = null
    query_type          = "native"
    parameters          = []
    parameter_mappings  = []
    visualization_settings = {
      "table.column_formatting" = [
        {
          columns       = ["change_type"]
          type          = "single"
          operator      = "="
          value         = "ADDED"
          color         = "#84BB4C"
          highlight_row = false
        },
        {
          columns       = ["change_type"]
          type          = "single"
          operator      = "="
          value         = "REMOVED"
          color         = "#EF8C8C"
          highlight_row = false
        }
      ]
    }
    dataset_query = {
      database   = metabase_database.postgres.id
      "lib/type" = "mbql/query"
      stages = [
        {
          "lib/type" = "mbql.stage/native"
          native     = <<-SQL
            SELECT
              change_type,
              app_name,
              entitlement_name,
              entitlement_type,
              via_source
            FROM audit.compare_access_between_dates(
              CAST({{start_date}} AS DATE),
              CAST({{end_date}} AS DATE) + INTERVAL '1 day' - INTERVAL '1 second'
            )
            WHERE TRUE
              [[AND email       = {{identity_email}}]]
              [[AND via_source  = {{source_filter}}]]
              [[AND change_type = {{change_type}}]]
            ORDER BY change_type, via_source, app_name, entitlement_name
          SQL
          "template-tags" = {
            start_date = {
              id             = "44444444-4444-4444-8444-444444444444"
              name           = "start_date"
              "display-name" = "Start Date"
              type           = "text"
              required       = true
            }
            end_date = {
              id             = "55555555-5555-4555-8555-555555555555"
              name           = "end_date"
              "display-name" = "End Date"
              type           = "text"
              required       = true
            }
            identity_email = {
              id             = "66666666-6666-4666-8666-666666666666"
              name           = "identity_email"
              "display-name" = "Identity Email"
              type           = "text"
              required       = false
            }
            source_filter = {
              id             = "77777777-7777-4777-8777-777777777777"
              name           = "source_filter"
              "display-name" = "Source"
              type           = "text"
              required       = false
            }
            change_type = {
              id             = "88888888-8888-4888-8888-888888888888"
              name           = "change_type"
              "display-name" = "Change Type (ADDED / REMOVED)"
              type           = "text"
              required       = false
            }
          }
        }
      ]
    }
  })
}

# ---------------------------
# Dashboard
# ---------------------------
resource "metabase_dashboard" "main" {
  name        = "Who Works Here"
  description = "Interactive directory of active humans by department, with drill-down to the full roster."

  parameters_json = jsonencode([
    {
      id        = "identity_search_dashboard"
      name      = "Search Identity"
      slug      = "identity_search"
      type      = "string/contains"
      sectionId = "string"
    },
    {
      id                 = "department_filter_dashboard"
      name               = "Department"
      slug               = "department"
      type               = "string/="
      sectionId          = "string"
      values_query_type  = "search"
      values_source_type = "card"
      values_source_config = {
        card_id     = metabase_card.department_values.id
        value_field = ["field", "department", { "base-type" = "type/Text" }]
      }
    },
    {
      id        = "account_search_dashboard"
      name      = "Search Account"
      slug      = "account_search"
      type      = "string/contains"
      sectionId = "string"
    },
    {
      id                 = "source_filter_ww_dashboard"
      name               = "Account Source"
      slug               = "account_source"
      type               = "string/="
      sectionId          = "string"
      values_query_type  = "list"
      values_source_type = "static-list"
      values_source_config = {
        values = ["ad", "crossid", "github", "hr"]
      }
    },
    {
      id                 = "status_filter_ww_dashboard"
      name               = "Account Status"
      slug               = "account_status"
      type               = "string/="
      sectionId          = "string"
      values_query_type  = "list"
      values_source_type = "static-list"
      values_source_config = {
        values = ["active", "inactive", "disabled"]
      }
    }
  ])

  cards_json = jsonencode([
    {
      card_id                = metabase_card.identities_count.id
      row                    = 0
      col                    = 0
      size_x                 = 6
      size_y                 = 3
      parameter_mappings     = []
      series                 = []
      visualization_settings = {}
    },
    {
      card_id            = metabase_card.humans_by_department.id
      row                = 0
      col                = 6
      size_x             = 12
      size_y             = 6
      parameter_mappings = []
      series             = []
      visualization_settings = {
        click_behavior = {
          type = "crossfilter"
        }
      }
    },
    {
      card_id                = metabase_card.stale_active_accounts_count.id
      row                    = 0
      col                    = 18
      size_x                 = 6
      size_y                 = 3
      parameter_mappings     = []
      series                 = []
      visualization_settings = {}
    },
    {
      card_id                = metabase_card.orphan_accounts_count.id
      row                    = 3
      col                    = 18
      size_x                 = 6
      size_y                 = 3
      parameter_mappings     = []
      series                 = []
      visualization_settings = {}
    },
    {
      card_id = metabase_card.identity_roster.id
      row     = 6
      col     = 0
      size_x  = 24
      size_y  = 8
      parameter_mappings = [
        {
          parameter_id = "identity_search_dashboard"
          card_id      = metabase_card.identity_roster.id
          target = [
            "dimension",
            [
              "field",
              metabase_table.identities.fields["display_name"],
              { "base-type" = "type/Text" }
            ]
          ]
        },
        {
          parameter_id = "department_filter_dashboard"
          card_id      = metabase_card.identity_roster.id
          target = [
            "dimension",
            [
              "field",
              metabase_table.identities.fields["department"],
              { "base-type" = "type/Text" }
            ]
          ]
        }
      ]
      series                 = []
      visualization_settings = {}
    },
    {
      card_id = metabase_card.active_accounts_without_recent_login.id
      row     = 14
      col     = 0
      size_x  = 24
      size_y  = 6
      parameter_mappings = [
        {
          parameter_id = "account_search_dashboard"
          card_id      = metabase_card.active_accounts_without_recent_login.id
          target = [
            "dimension",
            [
              "field",
              metabase_table.accounts.fields["username"],
              { "base-type" = "type/Text" }
            ]
          ]
        },
        {
          parameter_id = "source_filter_ww_dashboard"
          card_id      = metabase_card.active_accounts_without_recent_login.id
          target = [
            "dimension",
            [
              "field",
              metabase_table.accounts.fields["source"],
              { "base-type" = "type/Text" }
            ]
          ]
        },
        {
          parameter_id = "status_filter_ww_dashboard"
          card_id      = metabase_card.active_accounts_without_recent_login.id
          target = [
            "dimension",
            [
              "field",
              metabase_table.accounts.fields["status"],
              { "base-type" = "type/Text" }
            ]
          ]
        }
      ]
      series                 = []
      visualization_settings = {}
    },
    {
      card_id                = metabase_card.entitlement_relationships.id
      row                    = 20
      col                    = 0
      size_x                 = 24
      size_y                 = 6
      parameter_mappings     = []
      series                 = []
      visualization_settings = {}
    }
  ])
}

# ---------------------------
# Dashboard
# ---------------------------
resource "metabase_dashboard" "crossid_policy_coverage" {
  name        = "Crossid Policy Coverage"
  description = "Coverage dashboard for access outside Crossid policy. Latest-snapshot cards answer who is affected now; trend cards show whether policy coverage is improving or deteriorating over time."
  cards_json = jsonencode([
    {
      card_id            = null
      row                = 0
      col                = 0
      size_x             = 24
      size_y             = 4
      series             = []
      parameter_mappings = []
      visualization_settings = {
        virtual_card = {
          name                   = null
          display                = "text"
          visualization_settings = {}
          dataset_query          = {}
          archived               = false
        }
        text                  = <<-TEXT
          ## What this shows

          `Unapproved access` means an entitlement is granted in a downstream source system but is not covered by the Crossid wanted-state policy overlay.

          Crossid source rows are excluded from these analytics views so the dashboard stays focused on downstream systems like AD, GitHub, and HR.

          Start with `Primary Drivers: Identities with Unapproved Access`. That is the main triage list for operators and reviewers, ordered by the identities with the highest unapproved counts.

          Use the trend charts after that to understand whether policy coverage is improving over time.

          Click a name or email in the identity table to jump into `Access Investigations` with that identity pre-filled.
        TEXT
        "dashcard.background" = false
      }
    },
    {
      card_id                = metabase_card.crossid_affected_identities_latest.id
      row                    = 4
      col                    = 0
      size_x                 = 6
      size_y                 = 3
      parameter_mappings     = []
      series                 = []
      visualization_settings = {}
    },
    {
      card_id                = metabase_card.crossid_unapproved_entitlements_latest.id
      row                    = 4
      col                    = 6
      size_x                 = 6
      size_y                 = 3
      parameter_mappings     = []
      series                 = []
      visualization_settings = {}
    },
    {
      card_id                = metabase_card.crossid_unapproved_by_source_latest.id
      row                    = 4
      col                    = 12
      size_x                 = 12
      size_y                 = 6
      parameter_mappings     = []
      series                 = []
      visualization_settings = {}
    },
    {
      card_id            = metabase_card.crossid_unapproved_identities_latest.id
      row                = 10
      col                = 0
      size_x             = 24
      size_y             = 8
      parameter_mappings = []
      series             = []
      visualization_settings = {
        column_settings = {
          (jsonencode(["name", "display_name"])) = {
            column_title = "Name"
            click_behavior = {
              type     = "link"
              linkType = "dashboard"
              targetId = metabase_dashboard.investigations.id
              parameterMapping = {
                identity_email_dashboard = {
                  id = "identity_email_dashboard"
                  source = {
                    type = "column"
                    id   = "email"
                    name = "email"
                  }
                  target = {
                    type = "parameter"
                    id   = "identity_email_dashboard"
                  }
                }
              }
            }
          }
          (jsonencode(["name", "email"])) = {
            column_title = "Email"
            click_behavior = {
              type     = "link"
              linkType = "dashboard"
              targetId = metabase_dashboard.investigations.id
              parameterMapping = {
                identity_email_dashboard = {
                  id = "identity_email_dashboard"
                  source = {
                    type = "column"
                    id   = "email"
                    name = "email"
                  }
                  target = {
                    type = "parameter"
                    id   = "identity_email_dashboard"
                  }
                }
              }
            }
          }
          (jsonencode(["name", "department"])) = {
            column_title = "Department"
          }
          (jsonencode(["name", "unapproved_entitlement_count"])) = {
            column_title = "Unapproved Count"
          }
          (jsonencode(["name", "affected_account_count"])) = {
            column_title = "Affected Accounts"
          }
          (jsonencode(["name", "affected_sources"])) = {
            column_title = "Affected Sources"
          }
        }
      }
    },
    {
      card_id                = metabase_card.crossid_granted_vs_unapproved_over_time.id
      row                    = 18
      col                    = 0
      size_x                 = 12
      size_y                 = 6
      parameter_mappings     = []
      series                 = []
      visualization_settings = {}
    },
    {
      card_id                = metabase_card.crossid_unapproved_rate_over_time.id
      row                    = 18
      col                    = 12
      size_x                 = 12
      size_y                 = 6
      parameter_mappings     = []
      series                 = []
      visualization_settings = {}
    },
    {
      card_id                = metabase_card.crossid_unapproved_by_source_over_time.id
      row                    = 24
      col                    = 0
      size_x                 = 24
      size_y                 = 6
      parameter_mappings     = []
      series                 = []
      visualization_settings = {}
    }
  ])
}

# ---------------------------
# Dashboard
# ---------------------------
resource "metabase_dashboard" "investigations" {
  name        = "Access Investigations"
  description = "Point-in-time investigation workflow. Choose a date once, and both questions will evaluate access as of the end of that day so you can compare identity-centric and account-centric views."

  parameters_json = jsonencode([
    {
      id        = "snapshot_timestamp_dashboard"
      name      = "Snapshot Date"
      slug      = "snapshot_timestamp"
      type      = "date/single"
      sectionId = "date"
    },
    {
      id                   = "identity_email_dashboard"
      name                 = "Identity Email"
      slug                 = "identity_email"
      type                 = "string/="
      sectionId            = "string"
      values_query_type    = "search"
      values_source_type   = "card"
      values_source_config = {
        card_id     = metabase_card.identity_email_values.id
        value_field = ["field", "email", { "base-type" = "type/Text" }]
      }
    },
    {
      id                 = "account_source_dashboard"
      name               = "Account Source"
      slug               = "account_source"
      type               = "string/="
      sectionId          = "string"
      values_query_type  = "list"
      values_source_type = "static-list"
      values_source_config = {
        values = ["ad", "crossid", "github", "hr"]
      }
    },
    {
      id        = "account_username_dashboard"
      name      = "Account Username"
      slug      = "account_username"
      type      = "string/="
      sectionId = "string"
    }
  ])

  cards_json = jsonencode([
    {
      card_id = metabase_card.identity_summary_at_time.id
      row     = 0
      col     = 0
      size_x  = 24
      size_y  = 4
      parameter_mappings = [
        {
          parameter_id = "snapshot_timestamp_dashboard"
          card_id      = metabase_card.identity_summary_at_time.id
          target = [
            "variable",
            ["template-tag", "snapshot_timestamp"]
          ]
        },
        {
          parameter_id = "identity_email_dashboard"
          card_id      = metabase_card.identity_summary_at_time.id
          target = [
            "variable",
            ["template-tag", "identity_email"]
          ]
        }
      ]
      series                 = []
      visualization_settings = {}
    },
    {
      card_id = metabase_card.identity_access_at_time.id
      row     = 4
      col     = 0
      size_x  = 24
      size_y  = 8
      parameter_mappings = [
        {
          parameter_id = "snapshot_timestamp_dashboard"
          card_id      = metabase_card.identity_access_at_time.id
          target = [
            "variable",
            ["template-tag", "snapshot_timestamp"]
          ]
        },
        {
          parameter_id = "identity_email_dashboard"
          card_id      = metabase_card.identity_access_at_time.id
          target = [
            "variable",
            ["template-tag", "identity_email"]
          ]
        }
      ]
      series = []
      visualization_settings = {
        column_settings = {
          (jsonencode(["name", "via_account"])) = {
            column_title = "Via Account"
            click_behavior = {
              type     = "link"
              linkType = "dashboard"
              targetId = 3
              parameterMapping = {
                account_source_dashboard = {
                  id = "account_source_dashboard"
                  source = {
                    type = "column"
                    id   = "via_source"
                    name = "via_source"
                  }
                  target = {
                    type = "parameter"
                    id   = "account_source_dashboard"
                  }
                }
                account_username_dashboard = {
                  id = "account_username_dashboard"
                  source = {
                    type = "column"
                    id   = "via_account"
                    name = "via_account"
                  }
                  target = {
                    type = "parameter"
                    id   = "account_username_dashboard"
                  }
                }
              }
            }
          }
          (jsonencode(["name", "via_source"])) = {
            column_title = "Via Source"
          }
        }
      }
    },
    {
      card_id = metabase_card.account_access_at_time.id
      row     = 12
      col     = 0
      size_x  = 24
      size_y  = 8
      parameter_mappings = [
        {
          parameter_id = "snapshot_timestamp_dashboard"
          card_id      = metabase_card.account_access_at_time.id
          target = [
            "variable",
            ["template-tag", "snapshot_timestamp"]
          ]
        },
        {
          parameter_id = "account_source_dashboard"
          card_id      = metabase_card.account_access_at_time.id
          target = [
            "variable",
            ["template-tag", "account_source"]
          ]
        },
        {
          parameter_id = "account_username_dashboard"
          card_id      = metabase_card.account_access_at_time.id
          target = [
            "variable",
            ["template-tag", "account_username"]
          ]
        }
      ]
      series                 = []
      visualization_settings = {}
    }
  ])
}

# ---------------------------
# Dashboard: Common Entitlements
# ---------------------------
resource "metabase_dashboard" "common_entitlements_dashboard" {
  name        = "Common Entitlements"
  description = "Entitlements shared by a group of identities. Enter a comma-separated list of emails to see all entitlements every listed identity holds today. Use the Source filter to drill into a specific source system."

  parameters_json = jsonencode([
    {
      id                 = "identity_emails_dashboard"
      name               = "Identity Emails"
      slug               = "identity_emails"
      type               = "string/="
      sectionId          = "string"
      isMultiSelect      = true
      values_query_type  = "search"
      values_source_type = "card"
      values_source_config = {
        card_id     = metabase_card.identity_email_values.id
        value_field = ["field", "email", { "base-type" = "type/Text" }]
      }
    },
    {
      id                 = "source_filter_ce_dashboard"
      name               = "Source"
      slug               = "source_filter"
      type               = "string/="
      sectionId          = "string"
      values_query_type  = "list"
      values_source_type = "static-list"
      values_source_config = {
        values = ["ad", "crossid", "github", "hr"]
      }
    }
  ])

  cards_json = jsonencode([
    {
      card_id = metabase_card.common_entitlements.id
      row     = 0
      col     = 0
      size_x  = 24
      size_y  = 10
      parameter_mappings = [
        {
          parameter_id = "identity_emails_dashboard"
          card_id      = metabase_card.common_entitlements.id
          target       = ["variable", ["template-tag", "identity_emails"]]
        },
        {
          parameter_id = "source_filter_ce_dashboard"
          card_id      = metabase_card.common_entitlements.id
          target       = ["variable", ["template-tag", "source_filter"]]
        }
      ]
      series                 = []
      visualization_settings = {}
    }
  ])
}

# ---------------------------
# Dashboard: Entitlements Catalog
# ---------------------------
resource "metabase_dashboard" "entitlements_catalog_dashboard" {
  name        = "Entitlements Catalog"
  description = "Browse all entitlements with their description and sensitivity extracted from the attributes JSONB column. Use Search to filter by name."

  parameters_json = jsonencode([
    {
      id        = "entitlement_search_dashboard"
      name      = "Search"
      slug      = "search"
      type      = "string/="
      sectionId = "string"
    },
    {
      id        = "sensitivity_min_ec_dashboard"
      name      = "Min Sensitivity"
      slug      = "sensitivity_min"
      type      = "number/="
      sectionId = "number"
    },
    {
      id                   = "empty_sensitivity_ec_dashboard"
      name                 = "No Sensitivity"
      slug                 = "empty_sensitivity"
      type                 = "string/="
      sectionId            = "string"
      values_query_type    = "list"
      values_source_type   = "static-list"
      values_source_config = {
        values = ["yes"]
      }
    },
    {
      id                 = "source_filter_ec_dashboard"
      name               = "Source"
      slug               = "source_filter_ec"
      type               = "string/="
      sectionId          = "string"
      values_query_type  = "list"
      values_source_type = "static-list"
      values_source_config = {
        values = ["ad", "crossid", "github", "hr"]
      }
    }
  ])

  cards_json = jsonencode([
    {
      card_id = metabase_card.entitlements_catalog.id
      row     = 0
      col     = 0
      size_x  = 24
      size_y  = 10
      parameter_mappings = [
        {
          parameter_id = "entitlement_search_dashboard"
          card_id      = metabase_card.entitlements_catalog.id
          target       = ["variable", ["template-tag", "search"]]
        },
        {
          parameter_id = "sensitivity_min_ec_dashboard"
          card_id      = metabase_card.entitlements_catalog.id
          target       = ["variable", ["template-tag", "sensitivity_min"]]
        },
        {
          parameter_id = "empty_sensitivity_ec_dashboard"
          card_id      = metabase_card.entitlements_catalog.id
          target       = ["variable", ["template-tag", "empty_sensitivity"]]
        },
        {
          parameter_id = "source_filter_ec_dashboard"
          card_id      = metabase_card.entitlements_catalog.id
          target       = ["variable", ["template-tag", "source_filter_ec"]]
        }
      ]
      series                 = []
      visualization_settings = {}
    }
  ])
}

# ---------------------------
# Dashboard: Access Changes Between Dates
# ---------------------------
resource "metabase_dashboard" "access_changes" {
  name        = "Access Changes Between Dates"
  description = "Entitlement changes (ADDED / REMOVED) for a single identity between two chosen dates. The header row shows identity details and aggregate counts; the table lists each changed entitlement."

  parameters_json = jsonencode([
    {
      id        = "start_date_access"
      name      = "Start Date"
      slug      = "start_date"
      type      = "date/single"
      sectionId = "date"
    },
    {
      id        = "end_date_access"
      name      = "End Date"
      slug      = "end_date"
      type      = "date/single"
      sectionId = "date"
    },
    {
      id                 = "identity_email_access"
      name               = "Identity Email"
      slug               = "identity_email"
      type               = "string/="
      sectionId          = "string"
      values_query_type  = "search"
      values_source_type = "card"
      values_source_config = {
        card_id     = metabase_card.identity_email_values.id
        value_field = ["field", "email", { "base-type" = "type/Text" }]
      }
    },
    {
      id                 = "source_filter_access"
      name               = "Source"
      slug               = "source_filter"
      type               = "string/="
      sectionId          = "string"
      values_query_type  = "list"
      values_source_type = "static-list"
      values_source_config = {
        values = ["ad", "crossid", "github", "hr"]
      }
    },
    {
      id                 = "change_type_access"
      name               = "Change Type"
      slug               = "change_type"
      type               = "string/="
      sectionId          = "string"
      values_query_type  = "list"
      values_source_type = "static-list"
      values_source_config = {
        values = ["ADDED", "REMOVED"]
      }
    }
  ])

  cards_json = jsonencode([
    {
      card_id = metabase_card.identity_info.id
      row     = 0
      col     = 0
      size_x  = 14
      size_y  = 4
      parameter_mappings = [
        {
          parameter_id = "identity_email_access"
          card_id      = metabase_card.identity_info.id
          target       = ["variable", ["template-tag", "identity_email"]]
        }
      ]
      series                 = []
      visualization_settings = {}
    },
    {
      card_id = metabase_card.access_changes_added_count.id
      row     = 0
      col     = 14
      size_x  = 5
      size_y  = 4
      parameter_mappings = [
        {
          parameter_id = "start_date_access"
          card_id      = metabase_card.access_changes_added_count.id
          target       = ["variable", ["template-tag", "start_date"]]
        },
        {
          parameter_id = "end_date_access"
          card_id      = metabase_card.access_changes_added_count.id
          target       = ["variable", ["template-tag", "end_date"]]
        },
        {
          parameter_id = "identity_email_access"
          card_id      = metabase_card.access_changes_added_count.id
          target       = ["variable", ["template-tag", "identity_email"]]
        }
      ]
      series                 = []
      visualization_settings = {}
    },
    {
      card_id = metabase_card.access_changes_removed_count.id
      row     = 0
      col     = 19
      size_x  = 5
      size_y  = 4
      parameter_mappings = [
        {
          parameter_id = "start_date_access"
          card_id      = metabase_card.access_changes_removed_count.id
          target       = ["variable", ["template-tag", "start_date"]]
        },
        {
          parameter_id = "end_date_access"
          card_id      = metabase_card.access_changes_removed_count.id
          target       = ["variable", ["template-tag", "end_date"]]
        },
        {
          parameter_id = "identity_email_access"
          card_id      = metabase_card.access_changes_removed_count.id
          target       = ["variable", ["template-tag", "identity_email"]]
        }
      ]
      series                 = []
      visualization_settings = {}
    },
    {
      card_id = metabase_card.access_changes_between_dates.id
      row     = 4
      col     = 0
      size_x  = 24
      size_y  = 10
      parameter_mappings = [
        {
          parameter_id = "start_date_access"
          card_id      = metabase_card.access_changes_between_dates.id
          target       = ["variable", ["template-tag", "start_date"]]
        },
        {
          parameter_id = "end_date_access"
          card_id      = metabase_card.access_changes_between_dates.id
          target       = ["variable", ["template-tag", "end_date"]]
        },
        {
          parameter_id = "identity_email_access"
          card_id      = metabase_card.access_changes_between_dates.id
          target       = ["variable", ["template-tag", "identity_email"]]
        },
        {
          parameter_id = "source_filter_access"
          card_id      = metabase_card.access_changes_between_dates.id
          target       = ["variable", ["template-tag", "source_filter"]]
        },
        {
          parameter_id = "change_type_access"
          card_id      = metabase_card.access_changes_between_dates.id
          target       = ["variable", ["template-tag", "change_type"]]
        }
      ]
      series                 = []
      visualization_settings = {}
    }
  ])
}
