local helpers = require "spec.helpers"
local constants = require "kong.constants"
local cjson = require "cjson"
local pl_file = require "pl.file"

for _, strategy in helpers.each_strategy() do
  local proxy_client

  describe("tracing spec #" .. strategy, function()

    lazy_setup(function()
      local bp = assert(helpers.get_db_utils(strategy, {
        "services",
        "routes",
        "plugins",
      }, { "trace-echo-exporter" }))

      local http_srv = assert(bp.services:insert {
        name = "mock-service",
        host = helpers.mock_upstream_host,
        port = helpers.mock_upstream_port,
      })

      bp.routes:insert({ service = http_srv,
                         protocols = { "http" },
                         paths = { "/" }})

      bp.plugins:insert({
        name = "trace-echo-exporter",
        config = {}
      })

      assert(helpers.start_kong {
        database = strategy,
        nginx_conf = "spec/fixtures/custom_nginx.template",
        plugins = "trace-echo-exporter",
      })

      proxy_client = helpers.proxy_client()
    end)

    lazy_teardown(function()
      helpers.stop_kong()
    end)

    it("exporter works", function ()

      local thread = helpers.tcp_server(8189)

      local r = assert(proxy_client:send {
        method  = "GET",
        path    = "/",
      })
      assert.res_status(200, r)

      ngx.sleep(2)
      local _, res = assert(thread:join())
      assert.is_not_nil(res)
    end)
  end)
end
