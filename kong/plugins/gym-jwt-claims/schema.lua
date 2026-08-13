local typedefs = require "kong.db.schema.typedefs"
local jwt_decoder = require "kong.plugins.jwt.jwt_parser"

return {
  name = "gym-jwt-claims",
  fields = {
    { consumer = typedefs.no_consumer },
    { protocols = typedefs.protocols_http },
    {
      config = {
        type = "record",
        fields = {
          { public_keys = {
              type = "map",
              keys = { type = "string" },
              values = { type = "string" },
              required = true,
            }
          },
          { issuer = { type = "string", default = "gym-identifier" } },
          { audience = { type = "string", default = "gym-api" } },
          -- Kept only so historical G8 declarative fixtures remain loadable.
          { protected_routes = {
              type = "array",
              elements = { type = "string" },
              default = {}
            }
          },
          { protected_http_routes = {
              type = "array",
              elements = {
                type = "record",
                fields = {
                  { method = { type = "string", required = true, one_of = { "GET", "POST", "PUT", "PATCH", "DELETE" } } },
                  { path_regex = { type = "string", required = true } },
                },
              },
              default = {}
            }
          },
          -- Optional Redis blacklist (Identifier logout writes blacklist:<sha256(token)>).
          -- Empty host disables the check. No empty-string defaults — Kong rejects them.
          { redis_host = { type = "string", required = false } },
          { redis_port = { type = "number", default = 6379 } },
          { redis_password = { type = "string", required = false, referenceable = true } },
          { redis_timeout_ms = { type = "number", default = 50 } },
          { redis_database = { type = "number", default = 0 } },
        },
      },
    },
  },
}
