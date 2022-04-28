local helpers = require "spec.helpers"
local constants = require "kong.constants"
local cjson = require "cjson"
local pl_file = require "pl.file"

local TCP_PORT = 35001
for _, strategy in helpers.each_strategy() do
  local proxy_client

  describe("tracing spec #" .. strategy, function()

    lazy_setup(function()
      local bp = assert(helpers.get_db_utils(strategy, {
        "services",
        "routes",
        "plugins",
      }, { "tcp-trace-exporter" }))

      local http_srv = assert(bp.services:insert {
        name = "mock-service",
        host = helpers.mock_upstream_host,
        port = helpers.mock_upstream_port,
      })

      bp.routes:insert({ service = http_srv,
                         protocols = { "http" },
                         paths = { "/" }})

      bp.plugins:insert({
        name = "tcp-trace-exporter",
        config = {
          host = "127.0.0.1",
          port = TCP_PORT
        }
      })

      assert(helpers.start_kong {
        database = strategy,
        nginx_conf = "spec/fixtures/custom_nginx.template",
        plugins = "tcp-trace-exporter",
      })

      proxy_client = helpers.proxy_client()
    end)

    lazy_teardown(function()
      helpers.stop_kong()
    end)

    it("exporter works", function ()
      local thread = helpers.tcp_server(TCP_PORT)
      local r = assert(proxy_client:send {
        method  = "GET",
        path    = "/",
      })
      assert.res_status(200, r)

      -- Getting back the TCP server input
      local ok, res = thread:join()
      assert.True(ok)
      assert.is_string(res)

      -- Making sure it's alright
      local spans = cjson.decode(res)
      assert.is_same(2, #spans)
    end)
  end)
end
