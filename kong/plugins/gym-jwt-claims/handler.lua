local jwt_decoder = require "kong.plugins.jwt.jwt_parser"
local redis = require "resty.redis"
local sha256 = require "resty.sha256"
local str = require "resty.string"
local kong = kong

local GymJwtClaimsHandler = {
  PRIORITY = 1000,
  VERSION = "1.1.0",
}

local ALLOWED_ROLES = {
  CUSTOMER = true,
  TRAINER = true,
  ADMIN = true,
  SUPER_ADMIN = true,
}

local function strip_trusted_headers()
  kong.service.request.clear_header("x-user-id")
  kong.service.request.clear_header("x-user-role")
  kong.service.request.clear_header("x-gym-id")
  kong.service.request.clear_header("x-membership-status")
  kong.service.request.clear_header("x-trace-id")
end

local function is_route_in_list(path, list)
  if not list then return false end
  for _, pattern in ipairs(list) do
    if path:find(pattern) then
      return true
    end
  end
  return false
end

-- Identifier stores logout keys as blacklist:<sha256_hex(raw_access_token)>.
local function token_blacklist_key(token)
  local hasher = sha256:new()
  if not hasher then
    return nil, "sha256 unavailable"
  end
  hasher:update(token)
  return "blacklist:" .. str.to_hex(hasher:final())
end

-- Returns true when token is blacklisted. Redis misconfig/outage fails closed.
local function is_blacklisted(conf, token)
  if not conf.redis_host or conf.redis_host == "" then
    return false
  end
  local key, key_err = token_blacklist_key(token)
  if not key then
    kong.log.err("jwt blacklist hash failed: ", key_err)
    return true
  end
  local red = redis:new()
  red:set_timeout(conf.redis_timeout_ms or 50)
  local ok, err = red:connect(conf.redis_host, conf.redis_port or 6379)
  if not ok then
    kong.log.err("jwt blacklist redis connect failed: ", err)
    return true
  end
  if conf.redis_password and conf.redis_password ~= "" then
    local auth_ok, auth_err = red:auth(conf.redis_password)
    if not auth_ok then
      red:close()
      kong.log.err("jwt blacklist redis auth failed: ", auth_err)
      return true
    end
  end
  if conf.redis_database and conf.redis_database > 0 then
    local sel_ok, sel_err = red:select(conf.redis_database)
    if not sel_ok then
      red:close()
      kong.log.err("jwt blacklist redis select failed: ", sel_err)
      return true
    end
  end
  local exists, exists_err = red:exists(key)
  -- keepalive; ignore pool errors
  red:set_keepalive(10000, 20)
  if exists_err then
    kong.log.err("jwt blacklist redis exists failed: ", exists_err)
    return true
  end
  return exists == 1
end

function GymJwtClaimsHandler:access(conf)
  local path = kong.request.get_path()

  -- Step 1: Always strip incoming trusted headers from untrusted client
  strip_trusted_headers()

  -- Check if current path/method is protected
  local is_protected = is_route_in_list(path, conf.protected_routes)

  if not is_protected then
    -- Public route: trusted headers already stripped, pass through
    return
  end

  -- Protected route: Authorization header required
  local auth_header = kong.request.get_header("Authorization")
  if not auth_header then
    return kong.response.exit(401, { message = "Unauthorized: Missing Authorization header" })
  end

  local token = auth_header:match("^Bearer%s+(.+)$")
  if not token then
    return kong.response.exit(401, { message = "Unauthorized: Invalid Authorization header format" })
  end

  -- Decode JWT header and payload without signature verification first to inspect kid & alg
  local jwt, err = jwt_decoder:new(token)
  if err or not jwt then
    return kong.response.exit(401, { message = "Unauthorized: Malformed JWT token" })
  end

  local header = jwt.header
  local claims = jwt.claims

  -- Enforce RS256 algorithm only (reject none, HS256, etc.)
  if header.alg ~= "RS256" then
    return kong.response.exit(401, { message = "Unauthorized: Unsupported algorithm, RS256 required" })
  end

  -- Validate key ID (kid)
  local kid = header.kid
  if not kid or not conf.public_keys[kid] then
    return kong.response.exit(401, { message = "Unauthorized: Unknown key ID (kid)" })
  end

  local public_key_pem = conf.public_keys[kid]

  -- Verify signature using public key corresponding to kid
  if not jwt:verify_signature(public_key_pem) then
    return kong.response.exit(401, { message = "Unauthorized: Invalid token signature" })
  end

  -- Identifier Logout writes blacklist:<sha256(token)>; reject immediately when present.
  if is_blacklisted(conf, token) then
    return kong.response.exit(401, { message = "Unauthorized: Token has been revoked" })
  end

  -- Validate standard claims: iss, aud, exp
  if claims.iss ~= conf.issuer then
    return kong.response.exit(401, { message = "Unauthorized: Invalid issuer" })
  end

  if claims.aud ~= conf.audience then
    return kong.response.exit(401, { message = "Unauthorized: Invalid audience" })
  end

  local now = ngx.now()
  if type(claims.exp) ~= "number" or claims.exp <= now then
    return kong.response.exit(401, { message = "Unauthorized: Token has expired" })
  end

  if type(claims.iat) ~= "number" then
    return kong.response.exit(401, { message = "Unauthorized: Missing or invalid issued-at claim" })
  end

  if type(claims.jti) ~= "string" or claims.jti == "" then
    return kong.response.exit(401, { message = "Unauthorized: Missing or invalid JWT ID claim" })
  end

  if type(claims.sub) ~= "string" or claims.sub == "" then
    return kong.response.exit(401, { message = "Unauthorized: Missing subject (user ID)" })
  end

  -- Validate role claim
  local role = claims.role
  if not role or not ALLOWED_ROLES[role] then
    return kong.response.exit(403, { message = "Forbidden: Missing or invalid role claim" })
  end

  -- Inject validated claims into upstream trusted headers
  kong.service.request.set_header("x-user-id", claims.sub)
  kong.service.request.set_header("x-user-role", role)

  -- W3C traceparent/tracestate pass through unchanged; public x-trace-id is stripped.
end

return GymJwtClaimsHandler
