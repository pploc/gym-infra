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
          { protected_routes = {
              type = "array",
              elements = { type = "string" },
              default = {}
            }
          },
          { membership_gated_routes = {
              type = "array",
              elements = { type = "string" },
              default = {}
            }
          },
        },
      },
    },
  },
}
