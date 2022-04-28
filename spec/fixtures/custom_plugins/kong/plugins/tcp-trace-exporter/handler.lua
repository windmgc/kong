local cjson = require "cjson"

local ngx = ngx
local kong = kong
local table = table
local insert = table.insert


local _M = {
  PRIORITY = 1001,
}

local tracer_name = "tcp-trace-exporter"

function _M:rewrite(config)
  local tracer = kong.tracer(tracer_name)

  tracer.start_span("rewrite")
end


function _M:access(config)
  local tracer = kong.tracer(tracer_name)

  local span = tracer.start_span("access")
  span:finish()
end


local function push_data(premature, data, config)
  if premature then
    return
  end

  local tcpsock = ngx.socket.tcp()
  tcpsock:settimeout(1000)
  local ok, err = tcpsock:connect(config.host, config.port)
  if not ok then
    kong.log.err("connect err: ".. err)
    return
  end
  local _, err = tcpsock:send(data .. "\n")
  if err then
    kong.log.err(err)
  end
  tcpsock:close()
end

function _M:log(config)
  local tracer = kong.tracer(tracer_name)
  local span = tracer.active_span()

  if span then
    --print(inspect(span))
    span:finish()
  end

  local spans = {}
  tracer.process_span(function (span)
    local s = table.clone(span)
    s.tracer = nil
    insert(spans, s)
  end)

  local data = cjson.encode(spans)

  local ok, err = ngx.timer.at(0, push_data, data, config)
  if not ok then
    kong.log.err("failed to create timer: ", err)
  end
end


return _M
