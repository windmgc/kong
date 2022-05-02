local helpers = require "spec.helpers"
local cjson = require "cjson"

local TCP_PORT = 35001
for _, strategy in helpers.each_strategy() do
  local proxy_client

  describe("tracing instrumentations spec #" .. strategy, function()

    local function setup_instrumentations(types, custom_spans, enabled)
      local bp, _ = assert(helpers.get_db_utils(strategy, {
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
          port = TCP_PORT,
          custom_spans = custom_spans or false,
        }
      })

      assert(helpers.start_kong {
        database = strategy,
        nginx_conf = "spec/fixtures/custom_nginx.template",
        plugins = "tcp-trace-exporter",
        instrumentation_trace = enabled or "on",
        instrumentation_trace_types = types,
      })

      proxy_client = helpers.proxy_client()
    end

    describe("off", function ()
      lazy_setup(function()
        setup_instrumentations("db_query", false, "off")
      end)

      lazy_teardown(function()
        helpers.stop_kong()
      end)

      it("works", function ()
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
        assert.is_same(0, #spans, res)
      end)
    end)

    describe("db query", function ()
      lazy_setup(function()
        setup_instrumentations("db_query")
      end)

      lazy_teardown(function()
        helpers.stop_kong()
      end)

      it("works", function ()
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
        local expetecd_span_num = 2
        -- cassandra has different db query implementation
        if strategy == "cassandra" then
          expetecd_span_num = 4
        end
        assert.is_same(expetecd_span_num, #spans, res)
        assert.is_same("query", spans[2].name)
      end)
    end)

    describe("router", function ()
      lazy_setup(function()
        setup_instrumentations("router")
      end)

      lazy_teardown(function()
        helpers.stop_kong()
      end)

      it("works", function ()
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
        assert.is_same(2, #spans, res)
        assert.is_same("router", spans[2].name)
      end)
    end)

    describe("http_request", function ()
      lazy_setup(function()
        setup_instrumentations("http_request")
      end)

      lazy_teardown(function()
        helpers.stop_kong()
      end)

      it("works", function ()
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
        assert.is_same(1, #spans, res)
        assert.is_same("GET /", spans[1].name)
      end)
    end)

    describe("all", function ()
      lazy_setup(function()
        setup_instrumentations("all", true)
      end)

      lazy_teardown(function()
        helpers.stop_kong()
      end)

      it("works", function ()
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
        local expetecd_span_num = 5
        -- cassandra has different db query implementation
        if strategy == "cassandra" then
          expetecd_span_num = 7
        end
        assert.is_same(expetecd_span_num, #spans, res)
      end)
    end)
  end)
end
