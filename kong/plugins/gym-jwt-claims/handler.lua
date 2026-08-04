local jwt_decoder = require "kong.plugins.jwt.jwt_parser"
local kong = kong

local GymJwtClaimsHandler = {
  PRIORITY = 1000,
  VERSION = "1.0.0",
}

local ALLOWED_ROLES = {
  CUSTOMER = true,
  TRAINER = true,
  ADMIN = true,
  SUPER_ADMIN = true,
}

local ALLOWED_STATUSES = {
  NONE = true,
  ACTIVE = true,
  PAUSED = true,
  EXPIRED = true,
}

local function strip_trusted_headers()
  kong.service.request.clear_header("x-user-id")
  kong.service.request.clear_header("x-user-role")
  kong.service.request.clear_header("x-gym-id")
  kong.service.request.clear_header("x-membership-status")
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

function GymJwtClaimsHandler:access(conf)
  local path = kong.request.get_path()
  local method = kong.request.get_method()

  -- Step 1: Always strip incoming trusted headers from untrusted client
  strip_trusted_headers()

  -- Check if current path/method is protected
  local is_protected = is_route_in_list(path, conf.protected_routes)
  local is_membership_gated = is_route_in_list(path, conf.membership_gated_routes)

  if not is_protected and not is_membership_gated then
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

  -- Validate standard claims: iss, aud, exp
  if claims.iss ~= conf.issuer then
    return kong.response.exit(401, { message = "Unauthorized: Invalid issuer" })
  end

  if claims.aud ~= conf.audience then
    return kong.response.exit(401, { message = "Unauthorized: Invalid audience" })
  end

  local now = ngx.now()
  if not claims.exp or claims.exp <= now then
    return kong.response.exit(401, { message = "Unauthorized: Token has expired" })
  end

  if not claims.sub or claims.sub == "" then
    return kong.response.exit(401, { message = "Unauthorized: Missing subject (user ID)" })
  end

  -- Validate role claim
  local role = claims.role
  if not role or not ALLOWED_ROLES[role] then
    return kong.response.exit(403, { message = "Forbidden: Missing or invalid role claim" })
  end

  -- Validate membership_status claim
  local membership_status = claims.membership_status
  if not membership_status or not ALLOWED_STATUSES[membership_status] then
    return kong.response.exit(403, { message = "Forbidden: Missing or invalid membership_status claim" })
  end

  -- Membership gated routes require ACTIVE status
  if is_membership_gated then
    if membership_status ~= "ACTIVE" then
      return kong.response.exit(403, { message = "Forbidden: Active membership required for this route" })
    end
  end

  -- Inject validated claims into upstream trusted headers
  kong.service.request.set_header("x-user-id", claims.sub)
  kong.service.request.set_header("x-user-role", role)
  kong.service.request.set_header("x-gym-id", claims.gym_id or "")
  kong.service.request.set_header("x-membership-status", membership_status)

  -- Traceparent precedence rule (W3C traceparent preserved if valid; x-trace-id fallback handled downstream/upstream)
end

return GymJwtClaimsHandler
