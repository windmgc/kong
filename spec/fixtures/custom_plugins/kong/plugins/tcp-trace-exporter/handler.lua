local cjson = require "cjson"
local str = require "resty.string"

local ngx = ngx
local kong = kong
local table = table
local insert = table.insert
local to_hex = str.to_hex

local _M = {
  PRIORITY = 1001,
}

local tracer_name = "tcp-trace-exporter"

function _M:rewrite(config)
  local tracer = kong.tracing(tracer_name)

  local span = tracer.start_span("rewrite", {
    parent = kong.tracing.active_span(),
  })
  tracer.set_active_span(span)
end


function _M:access(config)
  local tracer = kong.tracing(tracer_name)

  local span = tracer.start_span("access")
  tracer.set_active_span(span)
  kong.db.routes:page()
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
  local tracer = kong.tracing(tracer_name)
  local span = tracer.active_span()

  if span then
    kong.log.debug("Exit span name: ", span.name)
    span:finish()
  end

  kong.log.debug("Total spans: ", #ngx.ctx.KONG_SPANS)

  local spans = {}
  local process_span = function (span)
    local s = table.clone(span)
    s.tracer = nil
    s.parent = nil
    s.trace_id = to_hex(s.trace_id)
    s.parent_id = s.parent_id and to_hex(s.parent_id)
    s.span_id = to_hex(s.span_id)
    insert(spans, s)
  end
  tracer.process_span(process_span)
  kong.tracing.process_span(process_span)

  local sort_by_start_time = function(a,b)
    return a.start_time_ns < b.start_time_ns
  end
  table.sort(spans, sort_by_start_time)

  local data = cjson.encode(spans)

  local ok, err = ngx.timer.at(0, push_data, data, config)
  if not ok then
    kong.log.err("failed to create timer: ", err)
  end
end


return _M
