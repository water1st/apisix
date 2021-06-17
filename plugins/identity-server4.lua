local ngx = ngx
local core = require("apisix.core")
local plugin = require("apisix.plugin")
local upstream = require("apisix.upstream")
local jwt =  require("resty.jwt")
local logger = core.log


local plugin_name = "identity-server4"


local schema = {
    type = "object",
    additionalProperties = false,
    properties = {},
}

local consumer_schema = {
    type = "object",
    properties = {
        identity_server_uri = {
            type = "string",
            minItems = 1
        },
        identity_server_admin_api_uri = {
            type = "string",
            minItems = 1
        },
        public_key = {
            type = "string",
            minItems = 1
        }
    }
}


local function split(str, d)
	local lst = { }
	local n = string.len(str)
	local start = 1
	while start <= n do
		local i = string.find(str, d, start)
		if i == nil then 
			table.insert(lst, string.sub(str, start, n))
			break 
		end
		table.insert(lst, string.sub(str, start, i-1))
		if i == n then
			table.insert(lst, "")
			break
		end
		start = i + 1
	end
	return lst
end

local function get_jwt_token(context)
    local token = core.request.header(context, "authorization")

    if token ~= nil and token ~= "" then
        
        local token_infos = split(token," ")
        local token_prefix = string.lower(token_infos[0])
        local jwt_token = token_infos[1]

        if token_prefix == "bearer" and jwt_token ~= nil and jwt_token ~= "" then
            return jwt_token
        end
    end

    return nil
end

local _M = {
    version = 0.1,
    priority = 2599,
    type = 'auth',
    name = plugin_name,
    schema = schema,
    consumer_schema = consumer_schema
}

function _M.rewrite(config, context)
    logger.warn("config：" .. core.json.encode(config, true))
    logger.warn("context：" .. core.json.encode(context, true))

    local jwt_token = get_jwt_token(context)
    if not jwt_token then
        logger.warn("token not found in header")
        return 401, { message = "Missing JWT token in request"}
    end

    local jwt_object = jwt:load_jwt(jwt_token)
    logger.warn("jwt object: ", core.json.delay_encode(jwt_object))
    if not jwt_object.valid then
        return 401, { message = jwt_object.reason }
    end

    local verified = jwt:verify_jwt_obj(config.public_key, jwt_object)
    if not verified then
        return 401, { message = jwt_object.reason }
    end

end

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

return _M