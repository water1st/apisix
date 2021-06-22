local core = require("apisix.core")
local jwt =  require("resty.jwt")
local logger = core.log
local http = require('resty.http')
local cjson = require('cjson')

local plugin_name = "identity-server4"

local discovery_info = {
    init = false,
    data = {}
}

local schema = {
    type = "object",
    properties = {
        issuer = {
            type = "string",
            minItems = 1
        },
        api_name = {
            type = "string",
            minItems = 1
        },
        api_secrets = {
            type = "string",
            minItems = 1
        },
        public_key = {
            type = "string",
            minItems = 1
        },
        introspect_type = {
            type = "string",
            enum = {"key", "issuer"}
        }
    },
    dependencies = {
        introspect_type = {
            oneOf = {
                {
                    properties = {
                        introspect_type = { type = "string", enum = { "key" } },
                        public_key = { type = "string" }
                    },
                    required = { "introspect_type" , "public_key" }
                },
                {
                    properties = {
                        introspect_type = { type = "string", enum = { "issuer" } },
                        api_secrets = { type = "string" },
                        api_name = { type = "string" }
                    },
                    required = { "introspect_type", "api_secrets", "api_name" }
                }
            }
        }
    },
    required = { "issuer", "introspect_type" }
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

local function encodeBase64(source_str)
    local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    local s64 = ''
    local str = source_str

    while #str > 0 do
        local bytes_num = 0
        local buf = 0

        for byte_cnt = 1,3 do
            buf = (buf * 256)
            if #str > 0 then
                buf = buf + string.byte(str, 1, 1)
                str = string.sub(str, 2)
                bytes_num = bytes_num + 1
            end
        end

        for group_cnt = 1,(bytes_num+1) do
            local b64char = math.fmod(math.floor(buf/262144), 64) + 1
            s64 = s64 .. string.sub(b64chars, b64char, b64char)
            buf = buf * 64
        end

        for fill_cnt = 1,(3-bytes_num) do
            s64 = s64 .. '='
        end
    end

    return s64
end



local function get_jwt_token(context)
    local token = core.request.header(context, "authorization")
    if token ~= nil and token ~= "" then
        
        local token_infos = split(token," ")
        local token_prefix = string.lower(token_infos[1])
        local jwt_token = token_infos[2]

        if token_prefix == "bearer" and jwt_token ~= nil and jwt_token ~= "" then
            return jwt_token
        end
    end

    return nil
end

local function get_discovery_endpoint(server)
    if string.sub(server,#server) == "/" then
        server = string.sub(server, 1, #server - 1)
    end

    local path = "/.well-known/openid-configuration"

    local endpoint = server .. path
    return endpoint
end

local function get_introspection_endpoint(issuer)
    if not discovery_info.init then

        local endpoint = get_discovery_endpoint(issuer)
        local http_client = http.new();
    
        local response, error = http_client:request_uri(endpoint,{
            method = "GET"
        })
    
        if not response then
            logger.error("request error: ", error)
        end

        local json_convert = cjson.new()
        local response_body = json_convert.decode(response.body)

        discovery_info.data = response_body
        discovery_info.init = true
    end

    local introspection_endpoint = discovery_info.data.introspection_endpoint
    return introspection_endpoint
end

local function contains(array,item)
    local result = false
    for index, value in ipairs(array) do
        if item == value then
            result = true
            break
        end
    end

    return result
end

local function introspect_by_key(issuer, public_key, token)
    local jwt_object = jwt:load_jwt(token)
    if not jwt_object.valid then
        return { success = false, code = 401 , response = { message = jwt_object.reason }}
    end

    local verified = jwt:verify_jwt_obj(public_key, jwt_object)
    if not verified then
        return { success = false, code = 401 , response = { message = jwt_object.reason }}
    end

    if  os.time() > jwt_object.payload.exp then
        return { success = false, code = 401 , response = { message = "token is has expired" }}
    end

    if issuer ~= jwt_object.payload.iss then
        return { success = false, code = 401 , response = { message = "invalid issuer" } }
    end

    local api_resources
    if jwt_object.payload.aud and type(jwt_object.payload.aud) == "string" then
        api_resources = { jwt_object.payload.aud }
    elseif jwt_object.payload.aud and type(jwt_object.payload.aud) == "table" then
        api_resources = jwt_object.payload.aud
    else
        api_resources = {}
    end

    return {success = true, api_resources = api_resources }
end

local function introspect_by_issuer(issuer, api_name, api_secrets, token)
    local endpoint = get_introspection_endpoint(issuer)
    local basic_token = encodeBase64(api_name .. ":" .. api_secrets)

    local http_client = http.new();
    local response, error = http_client:request_uri(endpoint,{
        method = "POST",
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
            ["Authorization"] = "Basic " .. basic_token
        },
        body = "token=" .. token
    })

    if not response then
        logger.error("request error: ", error)
    end

    local json_convert = cjson.new()
    local response_body = json_convert.decode(response.body)

    if not response_body.active then
        return { success = false, code = 401, response = { message = "invalid token" }}
    end

    if os.time() > response_body.exp then
        return { success = false, code = 401 , response = { message = "token is has expired" }}
    end

    if issuer ~= response_body.iss then
        return { success = false, code = 401 , response = { message = "invalid issuer" } }
    end

    local api_resources
    if response_body.aud and type(response_body.aud) == "string" then
        api_resources = { response_body.aud }
    elseif response_body.aud and type(response_body.aud) == "table" then
        api_resources = response_body.aud
    else
        api_resources = {}
    end

    return { success = true, api_resources = api_resources }
end

local _M = {
    version = 0.1,
    priority = 2599,
    type = 'auth',
    name = plugin_name,
    schema = schema
}

function _M.rewrite(config, context)
    local jwt_token = get_jwt_token(context)
    if not jwt_token then
        logger.info("token not found in header")
        return 401, { message = "missing jwt token in request"}
    end

    local result = nil

    if config.introspect_type == "key" then
        result = introspect_by_key(config.issuer, config.public_key, jwt_token)
    elseif config.introspect_type == "issuer" then
        result = introspect_by_issuer(config.issuer, config.api_name, config.api_secrets, jwt_token)
    else
        result = { success = false, code = 500, response = { message = "invalid introspect type" } }
    end

    if not result.success then
        return result.code, result.response
    end

    local service_name = context.matched_route.value.upstream.service_name
    if not contains(result.api_resources, service_name) then
        return 403, "invalid token permission"
    end
end

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

return _M