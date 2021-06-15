local require            = require
local local_conf         = require("apisix.core.config_local").local_conf()
local core               = require("apisix.core")
local cjson              = require('cjson')
local http               = require('resty.http')
local log                = core.log
local ipairs             = ipairs
local math               = math
local random             = math.random

local consul_conf = local_conf.discovery.consul

local schema = {
    type = "object",
    properties = {
        servers = {
            type = "array",
            minItems = 1,
            items = {
                type = "string"
            }
        },
        dc = {
            type = "string",
            minItems = 1
        },
        alc_token = {
            type = "string",
            minItems = 1
        }
    },
    required = {"servers"}
}

local function get_consul_server_endpoint(service_name)
    local server = consul_conf.servers[random(1, #consul_conf.servers)]
    if string.sub(server,#server) == "/" then
        server = string.sub(server, 1, #server - 1)
    end
    
    local path = "/v1/catalog/service/" .. service_name

    local split = "?"

    if consul_conf.dc ~= nil and consul_conf.dc ~= "" then
        path = path .. split .. "dc=" .. consul_conf.dc
        if split == "?" then
            split = "&"
        end
    end

    if consul_conf.alc_token ~= nil and #consul_conf.aalc_tokenlc ~= "" then
        path = path .. split .. "token=" .. consul_conf.alc_token
        if split == "?" then
            split = "&"
        end
    end

    local endpoint = server .. path
    
    return endpoint
end


local function get_nodes(service_name)
    -- 获取 consul 服务器节点
    local endpoint = get_consul_server_endpoint(service_name)

    local http_client = http.new()

    -- 向consul服务器发起http请求，获取服务节点
    local response, error = http_client:request_uri(endpoint, {
        method = "GET"
    })

    if not response then
        log.error("request error: ", error)
        return
    end

    -- 反序列化
    local json_convert = cjson.new()
    local response_body = json_convert.decode(response.body)

    if not response_body or #response_body == 0 then
        log.error("cannot get service ["..service_name.."] nodes, please check the service status in consul")
        return
    end

    local nodes = {}

    -- 转化为apisix需要的格式
    for index, node in ipairs(response_body) do
        nodes[index] = {
            host = node.ServiceAddress,
            port = node.ServicePort,
            weight = 100,
            metadata = {
                management = {
                    port = node.ServicePort
                }
            }
        }
    end

    return nodes
end

local _M = {
    version = 0.1,
}

-- 获取服务节点列表
function _M.nodes(service_name)
    local nodes = get_nodes(service_name)
    return nodes
end

-- 初始化
function _M.init_worker()
    -- 检查是否有配置
    local ok, err = core.schema.check(schema, consul_conf)
    if not ok
        then
            log.error("invalid config" .. err)
            return
        end
end


return _M