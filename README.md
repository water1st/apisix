# APISIX

apisix为api网关，本项目为二次开发的Consul支持和Identity Server4插件，其他文档参考[APISIX官网](http://apisix.apache.org/)获取



### 启用Consul支持

1、在apisix节点把`consul.lua`挂载到`/usr/local/apisix/apisix/discovery/`

```yml
        volumes: 
            - ./logs:/usr/local/apisix/logs
            - ./config/apisix_config.yaml:/usr/local/apisix/conf/config.yaml:ro
            - ./discovery/consul.lua:/usr/local/apisix/apisix/discovery/consul.lua:ro
```

2、修改配置 `./config/apisix_config.yam`

```yml
discovery:
  consul:
    servers:
      - "http://consul-node1:8500"
      - "http://consul-node2:8500"
      - "http://consul-node3:8500"
      - "http://consul-node4:8500"
    dc: "dc1"
    alc_token: "xxx"
```
| 字段名    | 类型   | 说明               |
| --------- | ------ | ------------------ |
| servers   | array  | consul节点         |
| dc        | string | consul数据中心名称 |
| alc_token | string | alc token（选填）  |

3、确保apisix、consul、上游服务都在同一个网络

4、启动容器

```bash
docker-compose up -d
```

5、打开浏览器在dashboard为路由配置`upstream`字段

```json
{
  "uris": [
    "/test/*"
  ],
  "name": "test",
  "methods": ["GET"],
  "plugins": {
    "proxy-rewrite": {
      "regex_uri": [
        "^/test/(.*)",
        "/${1}"
      ]
    }
  },
  "upstream": {
    "type": "roundrobin",
    "discovery_type": "consul",
    "service_name": "TestService"
  }
}
```

| 字段           | 类型   | 说明                   |
| -------------- | ------ | ---------------------- |
| type           | string | 负载均衡策略           |
| discovery_type | string | 服务发现类型，"consul" |
| service_name   | string | 服务名                 |



### 启用Identity Server 4插件

1、要启用IdentityServer4插件，必须先启用Consul服务发现模块

2、确保服务在Consul的注册的`ServiceName`与IdentityServer4的`Api Resource`的`Name`一样

3、在apisix节点把`identity-server4.lua`挂载到`/usr/local/apisix/apisix/plugins/`

```yml
        volumes: 
            - ./logs:/usr/local/apisix/logs
            - ./config/apisix_config.yaml:/usr/local/apisix/conf/config.yaml:ro
            - ./discovery/consul.lua:/usr/local/apisix/apisix/discovery/consul.lua:ro
            - ./plugins/identity-server4.lua:/usr/local/apisix/apisix/plugins/identity-server4.lua:ro
```

4、在apisix-dashboard节点把`schema.json`挂载到`/usr/local/apisix-dashboard/conf/`

```yml
        volumes: 
            - ./config/apisix_dashboard_config.yaml:/usr/local/apisix-dashboard/conf/conf.yaml:ro
            - ./config/schema.json:/usr/local/apisix-dashboard/conf/schema.json:ro
```

5 修改 `apisix_config.yaml`和`apisix_dashboard_config.yaml`添加`plugins`配置
```yml
plugins:                          # plugin list (sorted in alphabetical order)
  - identity-server4
```
6、确保apisix、consul、identityserver4、上游服务都在同一个网络

7、启动容器

```bash
docker-compose up -d
```

8、在dashboard启用插件并添加配置



采用公钥自省

```json
{
  "introspect_type": "key",
  "issuer": "https://your.identity.server",
  "public_key": "-----BEGIN PUBLIC KEY-----Your Public Key-----END PUBLIC KEY-----"
}
```
采用IdentityServer4自省
```json
{
  "introspect_type": "issuer",
  "issuer": "https://your.identity.server",
  "api_name": "your api name",
  "api_secrets": "your api secrets"
}
```



| 字段 | 数据类型 | 必填 | 说明 |
|--------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------|
|introspect_type | string | 必填                                                                                      | 自省方式，枚举类型，可选"issuer"、"key"                                                     |
|issuer | string | 必填 | IdentityServer4的url |
|api_name | string | 如果introspect_type = "issuer" 则为必填 | apisix在identityserver4注册的api resource name |
|api_secrets | string | 如果introspect_type  = "issuer" 则为必填 | apisix在identityserver4注册的api resource secrets |
|public_key | string | 如果introspect_type  = "key" 则为必填 | IdentityServer4使用证书的rsa公钥 |
