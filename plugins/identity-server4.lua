local ngx = ngx
local core = require("apisix.core")
local plugin = require("apisix.plugin")
local upstream = require("apisix.upstream")
local jwt =  require("resty.jwt")
local logger = core.log
local http = require('resty.http')
local cjson = require('cjson')

local plugin_name = "identity-server4"

local discovery_info = {
    init = false,
    data = {}
}

local access_token = {
    access_token = "",
    expiration_time = -1,
    token_type = ""
}

local schema = {
    type = "object",
    properties = {
        identity_server_uri = {
            type = "string",
            minItems = 1
        },
        apisix_api_name = {
            type = "string",
            minItems = 1
        },
        apisix_api_secrets = {
            type = "string",
            minItems = 1
        },
        public_key = {
            type = "string",
            minItems = 1
        },
        introspect_type = {
            type = "string",
            enum = {"public_key", "identity_server"}
        },
        identity_server_admin_api_uri = {
            type = "string",
            minItems = 1
        },
        identity_server_admin_api_client_client_id = {
            type = "string",
            minItems = 1
        },
        identity_server_admin_api_client_grant_type = {
            type = "string",
            minItems = 1
        },
        identity_server_admin_api_client_client_secret = {
            type = "string",
            minItems = 1
        },
        identity_server_admin_api_client_scopes = {
            type = "string",
            minItems = 1
        }

    },
    dependencies = {
        introspect_type = {
            oneOf = {
                {
                    properties = {
                        introspect_type = { type = "string", enum = { "public_key" } },
                        public_key = { type = "string" }
                    },
                    required = { "introspect_type" , "public_key" }
                },
                {
                    properties = {
                        introspect_type = { type = "string", enum = { "identity_server" } },
                        apisix_api_secrets = { type = "string" },
                        apisix_api_name = { type = "string" }
                    },
                    required = { "introspect_type", "apisix_api_secrets", "apisix_api_name" }
                }
            }
        }
    },
    required = {"identity_server_uri",
                "introspect_type",
                "identity_server_admin_api_uri",
                "identity_server_admin_api_client_client_id",
                "identity_server_admin_api_client_grant_type",
                "identity_server_admin_api_client_client_secret",
                "identity_server_admin_api_client_scopes"}
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

local function request_discovery_endpoint(identity_server_uri)
    if not discovery_info.init then

        local endpoint = get_discovery_endpoint(identity_server_uri)
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
end

local function get_introspection_endpoint(identity_server_uri)
    request_discovery_endpoint(identity_server_uri)

    local introspection_endpoint = discovery_info.data.introspection_endpoint
    return introspection_endpoint
end

local function get_token_endpoint(identity_server_uri)
    request_discovery_endpoint(identity_server_uri)

    local token_endpoint = discovery_info.data.token_endpoint
    return token_endpoint
end

local function get_apisix_client_info(config)
    local info = "client_id=" .. config.identity_server_admin_api_client_client_id
    info = info .. "&grant_type=" .. config.identity_server_admin_api_client_grant_type
    info = info .. "&client_secret=" .. config.identity_server_admin_api_client_client_secret
    info = info .. "&scopes=" .. config.identity_server_admin_api_client_scopes
    return info
end

local function get_access_token(config)
    if access_token.expiration_time == -1 or os.time() > access_token.expiration_time then
        local endpoint = get_token_endpoint(config.identity_server_uri)
        local client_info = get_apisix_client_info(config)
        local http_client = http.new();
        local response, error = http_client:request_uri(endpoint,{
            method = "POST",
            headers = {
                ["Content-Type"] = "application/x-www-form-urlencoded",
            },
            body = client_info
        })
    
        if not response then
            logger.error("request error: ", error)
        end
    
        local json_convert = cjson.new()
        local response_body = json_convert.decode(response.body)

        access_token.access_token = response_body.access_token
        access_token.token_type = response_body.token_type
        access_token.expiration_time = os.time() + response_body.expires_in
    end

    return access_token.token_type .. " " .. access_token.access_token
end

local function authorize(config, token_info)
    local access_token = get_access_token(config)

end

local function introspect_by_public_key(public_key, token)
    local jwt_object = jwt:load_jwt(token)
    if not jwt_object.valid then
        return { success = false, code = 401 , response = { message = jwt_object.reason }}
    end

    local verified = jwt:verify_jwt_obj(public_key, jwt_object)
    if not verified then
        return { success = false, code = 401 , response = { message = jwt_object.reason }}
    end

    if jwt_object.payload.exp <= os.time() then
        return { success = false, code = 401 , response = { message = "token is has expired" }}
    end

    return {success = true, data = {
        api_scopes = jwt_object.payload.scope,
        api_resources = jwt_object.payload.aud,
        client_id = jwt_object.payload.client_id
    }}
end

local function introspect_by_identity_server(identity_server_uri, api_name, api_secrets,token)
    local endpoint = get_introspection_endpoint(identity_server_uri)
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

    return { success = true, data = {
        api_scopes = split(response_body.scope, " "),
        api_resources = response_body.aud,
        client_id = response_body.client_id
    }}
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
        return 401, { message = "Missing JWT token in request"}
    end

    local result = nil

    if config.introspect_type == "public_key" then
        result = introspect_by_public_key(config.public_key, jwt_token)
    elseif config.introspect_type == "identity_server" then
        result = introspect_by_identity_server(config.identity_server_uri, config.apisix_api_name, config.apisix_api_secrets, jwt_token)
    else
        result = { success = false, code = 500, response = { message = "invalid introspect type" } }
    end

    if not result.success then
        return result.code, result.response
    end
end

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

return _M