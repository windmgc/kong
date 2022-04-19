local bu = require "spec.fixtures.balancer_utils"
local helpers = require "spec.helpers"


local https_server = helpers.https_server


for _, strategy in helpers.each_strategy() do
  for mode, localhost in pairs(bu.localhosts) do
    describe("Balancing with consistent hashing #" .. mode, function()
      local bp

      describe("over multiple targets", function()
        lazy_setup(function()
          bp = bu.get_db_utils_for_dc_and_admin_api(strategy, {
            "routes",
            "services",
            "plugins",
            "upstreams",
            "targets",
          })

          assert(helpers.start_kong({
            database   = strategy,
            nginx_conf = "spec/fixtures/custom_nginx.template",
            plugins    = "post-function",
            db_update_frequency = 0.1,
          }, nil, nil, nil))

        end)

        lazy_teardown(function()
          helpers.stop_kong()
        end)

        it("hashing on header", function()
          local requests = bu.SLOTS * 2 -- go round the balancer twice

          bu.begin_testcase_setup(strategy, bp)
          local upstream_name, upstream_id = bu.add_upstream(bp, {
            hash_on = "header",
            hash_on_header = "hashme",
          })
          local port1 = bu.add_target(bp, upstream_id, localhost)
          local port2 = bu.add_target(bp, upstream_id, localhost)
          local api_host = bu.add_api(bp, upstream_name)
          bu.end_testcase_setup(strategy, bp)

          -- setup target servers
          local server1 = https_server.new(port1, localhost)
          local server2 = https_server.new(port2, localhost)
          server1:start()
          server2:start()

          -- Go hit them with our test requests
          local oks = bu.client_requests(requests, {
            ["Host"] = api_host,
            ["hashme"] = "just a value",
          })
          assert.are.equal(requests, oks)

          -- collect server results; hitcount
          -- one should get all the hits, the other 0
          local count1 = server1:shutdown()
          local count2 = server2:shutdown()

          -- verify
          assert(count1.total == 0 or count1.total == requests, "counts should either get 0 or ALL hits")
          assert(count2.total == 0 or count2.total == requests, "counts should either get 0 or ALL hits")
          assert(count1.total + count2.total == requests)
        end)

        it("hashing on missing header", function()
          local requests = bu.SLOTS * 2 -- go round the balancer twice

          bu.begin_testcase_setup(strategy, bp)
          local upstream_name, upstream_id = bu.add_upstream(bp, {
            hash_on = "header",
            hash_on_header = "hashme",
          })
          local port1 = bu.add_target(bp, upstream_id, localhost)
          local port2 = bu.add_target(bp, upstream_id, localhost)
          local api_host = bu.add_api(bp, upstream_name)
          bu.end_testcase_setup(strategy, bp)

          -- setup target servers
          local server1 = https_server.new(port1, localhost)
          local server2 = https_server.new(port2, localhost)
          server1:start()
          server2:start()

          -- Go hit them with our test requests
          local oks = bu.client_requests(requests, {
            ["Host"] = api_host,
            ["nothashme"] = "just a value",
          })
          assert.are.equal(requests, oks)

          -- collect server results; hitcount
          -- one should get all the hits, the other 0
          local count1 = server1:shutdown()
          local count2 = server2:shutdown()

          -- verify
          assert(count1.total == 0 or count1.total == requests, "counts should either get 0 or ALL hits")
          assert(count2.total == 0 or count2.total == requests, "counts should either get 0 or ALL hits")
          assert(count1.total + count2.total == requests)
        end)

        describe("hashing on cookie", function()
          it("does not reply with Set-Cookie if cookie is already set", function()
            bu.begin_testcase_setup(strategy, bp)
            local upstream_name, upstream_id = bu.add_upstream(bp, {
              hash_on = "cookie",
              hash_on_cookie = "hashme",
            })
            local port = bu.add_target(bp, upstream_id, localhost)
            local api_host = bu.add_api(bp, upstream_name)
            bu.end_testcase_setup(strategy, bp)

            -- setup target server
            local server = https_server.new(port, localhost)
            server:start()

            -- send request
            local client = helpers.proxy_client()
            local res = client:send {
              method = "GET",
              path = "/",
              headers = {
                ["Host"] = api_host,
                ["Cookie"] = "hashme=some-cookie-value",
              }
            }
            local set_cookie = res.headers["Set-Cookie"]

            client:close()
            server:shutdown()

            -- verify
            assert.is_nil(set_cookie)
          end)

          it("replies with Set-Cookie if cookie is not set", function()
            local requests = bu.SLOTS * 2 -- go round the balancer twice

            bu.begin_testcase_setup(strategy, bp)
            local upstream_name, upstream_id = bu.add_upstream(bp, {
              hash_on = "cookie",
              hash_on_cookie = "hashme",
            })
            local port1 = bu.add_target(bp, upstream_id, localhost)
            local port2 = bu.add_target(bp, upstream_id, localhost)
            local api_host = bu.add_api(bp, upstream_name)
            bu.end_testcase_setup(strategy, bp)

            -- setup target servers
            local server1 = https_server.new(port1, localhost)
            local server2 = https_server.new(port2, localhost)
            server1:start()
            server2:start()

            -- initial request without the `hash_on` cookie
            local client = helpers.proxy_client()
            local res = client:send {
              method = "GET",
              path = "/",
              headers = {
                ["Host"] = api_host,
                ["Cookie"] = "some-other-cooke=some-other-value",
              }
            }
            local cookie = res.headers["Set-Cookie"]:match("hashme%=(.*)%;")

            client:close()

            -- subsequent requests add the cookie that was set by the first response
            local oks = 1 + bu.client_requests(requests - 1, {
              ["Host"] = api_host,
              ["Cookie"] = "hashme=" .. cookie,
            })
            assert.are.equal(requests, oks)

            -- collect server results; hitcount
            -- one should get all the hits, the other 0
            local count1 = server1:shutdown()
            local count2 = server2:shutdown()

            -- verify
            assert(count1.total == 0 or count1.total == requests,
                   "counts should either get 0 or ALL hits, but got " .. count1.total .. " of " .. requests)
            assert(count2.total == 0 or count2.total == requests,
                   "counts should either get 0 or ALL hits, but got " .. count2.total .. " of " .. requests)
            assert(count1.total + count2.total == requests)
          end)

        end)

        local function test_with_uri(uri, expect, upstream)
          local requests = bu.SLOTS * 2 -- go round the balancer twice

          bu.begin_testcase_setup(strategy, bp)
          local upstream_name, upstream_id = bu.add_upstream(bp, upstream)

          local port1 = bu.add_target(bp, upstream_id, localhost)
          local port2 = bu.add_target(bp, upstream_id, localhost)
          local api_host = bu.add_api(bp, upstream_name)

          -- setup target servers
          local server1 = https_server.new(port1, localhost)
          local server2 = https_server.new(port2, localhost)
          server1:start()
          server2:start()

          bu.end_testcase_setup(strategy, bp)

          local client = helpers.proxy_client()
          local res = assert(client:request({
            method = "GET",
            path = uri,
            headers = { host = api_host },
          }))

          -- Go hit them with our test requests
          local oks = bu.client_requests(requests, api_host, nil, nil, nil, uri)

          -- collect server results; hitcount
          -- one should get all the hits, the other 0
          local count1 = server1:shutdown()
          local count2 = server2:shutdown()

          -- verify
          assert.res_status(200, res)

          local hash = assert.response(res).has_header("x-balancer-hash-value")
          assert.equal(expect, hash)

          local req_uri = assert.response(res).has_header("x-uri")
          assert.equal(uri, req_uri) -- sanity

          assert.equal(requests, oks)

          -- account for our hash_value test request
          requests = requests + 1

          assert(count1.total == 0 or count1.total == requests, "counts should either get 0 or ALL hits")
          assert(count2.total == 0 or count2.total == requests, "counts should either get 0 or ALL hits")
          assert(count1.total + count2.total == requests)
        end

        describe("hashing on path", function()
          it("simple case", function()
            test_with_uri("/my-path", "/my-path", {
              hash_on = "path",
            })
          end)

          it("only uses the path component", function()
            test_with_uri("/my-path?a=1&b=2", "/my-path", {
              hash_on = "path",
            })
          end)

          it("uses the normalized path", function()
            test_with_uri("/root/../%2e/root///././%2F.subdir/../.subdir/./%28%29",
                          "/root/.subdir/()",
                          { hash_on = "path" })
          end)
        end)

        describe("hashing on a query string arg", function()
          it("when the arg is present in the request", function()
            test_with_uri("/?hashme=123", "123", {
              hash_on = "query_arg",
              hash_on_query_arg = "hashme",
            })
          end)

          it("when the arg is not present in request", function()
            test_with_uri("/", "NONE", {
              hash_on = "query_arg",
              hash_on_query_arg = "hashme",
            })
          end)

          it("as a fallback", function()
            test_with_uri("/?fallback=123", "123", {
              hash_on = "query_arg",
              hash_on_query_arg = "absent",
              hash_fallback = "query_arg",
              hash_fallback_query_arg = "fallback",
            })
          end)

          -- we use the $arg_<name> interface for extracting the query arg from
          -- the request, so only the first value is found
          it("multi value", function()
            test_with_uri("/?foo=first&foo=second", "first", {
              hash_on = "query_arg",
              hash_on_query_arg = "foo",
            })
          end)
        end)
      end)
    end)
  end
end
