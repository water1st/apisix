# APISIX


### 服务发现
需要把脚本挂载到容器内部的```/usr/local/apisix/apisix/discovery/```路径下
如```./discovery/consul.lua:/usr/local/apisix/apisix/discovery/consul.lua```

修改配置
`config/apisix_config.yam`

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
其中`discovery`下的子节点命名，必须和脚本同名，如`consul.lua`，其节点必须为其中`discovery`下的子节点命名，必须和脚本同名，如`consul`
`consule`节点下，`servers`是必填项，`dc`和`alc_token`为选项

之后在每个路由配置为使用服务发现配置`upstream`字段
```json
  "uris":["/test/*"],
  "name":"test",
  "methods":["GET"],
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
```


