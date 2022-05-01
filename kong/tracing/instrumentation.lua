local table       = table
local pack        = table.pack
local unpack      = table.unpack
local fmt         = string.format
local base        = require "resty.core.base"
local to_hex      = require "resty.string".to_hex
local pdk_tracer  = require "kong.pdk.tracing".new()
-- TODO(mayo): Bring the propagation library into PDK and make it possible to register custom handlers
local propagation = require "kong.plugins.zipkin.tracing_headers"
local time_ns     = require "kong.tools.utils".time_ns
local tablepool   = require "tablepool"

local _M = {}
local noop_mt = {
  __index = function()
    return function() end
  end
}


local instrument_tracer = pdk_tracer


local function start_root_span()
  if not base.get_request() then
    return
  end

  local active_span = instrument_tracer.active_span()
  if active_span then
    return active_span
  end

  local start_time = ngx.ctx.KONG_PROCESSING_START
      and ngx.ctx.KONG_PROCESSING_START * 100000
      or time_ns()

  -- we will later modify the span name, span_id
  local root_span = instrument_tracer.start_span("kong request", {
    start_time_ns = start_time,
  })
  instrument_tracer.set_active_span(root_span)
end

local wrap_func
do
  local wrap_mt = {
    __call = function(self, ...)
      start_root_span()
      local span = instrument_tracer.start_span(self.name)
      local ret = pack(self.f(...))
      span:finish()
      return unpack(ret)
    end
  }

  function wrap_func(name, f)
    return setmetatable({
      name = name, -- span name
      f = f, -- callback
    }, wrap_mt)
  end
end


local instrumentations = {}


local function set_headers(found_header_type, proxy_span)
  local set_header = kong.service.request.set_header
  found_header_type = found_header_type or "ot"

  if found_header_type == "b3"
  then
    set_header("x-b3-traceid", to_hex(proxy_span.trace_id))
    set_header("x-b3-spanid", to_hex(proxy_span.span_id))
    if proxy_span.parent_id then
      set_header("x-b3-parentspanid", to_hex(proxy_span.parent_id))
    end
    local Flags = kong.request.get_header("x-b3-flags") -- Get from request headers
    if Flags then
      set_header("x-b3-flags", Flags)
    else
      set_header("x-b3-sampled", proxy_span.sampled and "1" or "0")
    end
  end

  if found_header_type == "b3-single" then
    set_header("b3", fmt("%s-%s-%s-%s",
      to_hex(proxy_span.trace_id),
      to_hex(proxy_span.span_id),
      proxy_span.sampled and "1" or "0",
      to_hex(proxy_span.parent_id)))
  end

  if found_header_type == "w3c" then
    set_header("traceparent", fmt("00-%s-%s-%s",
      to_hex(proxy_span.trace_id),
      to_hex(proxy_span.span_id),
      proxy_span.sampled and "01" or "00"))
  end

  if found_header_type == "jaeger" then
    set_header("uber-trace-id", fmt("%s:%s:%s:%s",
      to_hex(proxy_span.trace_id),
      to_hex(proxy_span.span_id),
      to_hex(proxy_span.parent_id),
      proxy_span.sampled and "01" or "00"))
  end

  if found_header_type == "ot" then
    set_header("ot-tracer-traceid", to_hex(proxy_span.trace_id))
    set_header("ot-tracer-spanid", to_hex(proxy_span.span_id))
    set_header("ot-tracer-sampled", proxy_span.sampled and "1" or "0")
  end
end

-- http_request (root span)
function instrumentations.http_request()
  local req = kong.request

  local headers = req.get_headers()
  local header_type, trace_id, span_id, parent_id, sampled, _ = propagation.parse(headers)
  local method = req.get_method()
  local path = req.get_path()
  local span_name = method .. " " .. path

  -- TODO(mayo): add host, port...
  local active_span = instrument_tracer.active_span()
  if not active_span then
    active_span = instrument_tracer.start_span(span_name, {
      trace_id = trace_id,
      span_id = span_id,
      parent_id = parent_id,
      sampled = sampled,
    })
    instrument_tracer.set_active_span(active_span)
  else
    active_span.name = span_name
    if trace_id then
      active_span.trace_id = trace_id
    end

    if parent_id then
      active_span.parent_id = parent_id
    end

    if sampled ~= nil then
      active_span.sampled = sampled
    end
  end

  active_span:set_attribute("http.host", req.get_host())

  set_headers(header_type, active_span)
end

-- db query
function instrumentations.db_query(connector)
  local f = connector.query

  local function wrap(self, sql, ...)
    start_root_span()
    local span = instrument_tracer.start_span("query", {
      attributes = {
        sql = sql,
      }
    })
    local ret = pack(f(self, sql, ...))
    span:finish()
    return unpack(ret)
  end

  connector.query = wrap
end

-- router
function instrumentations.router(router)
  local f = router.exec
  router.exec = wrap_func("router", f)
end

function instrumentations.runloop_log_before(ctx)
  local root_span = instrument_tracer.active_span()
  if root_span then
    root_span:finish()
  end
end

function instrumentations.runloop_log_after(ctx)
  -- Clears the span table and put back the table pool,
  -- this avoids reallocation.
  -- The span table MUST NOT be used after released.
  if type(ctx.KONG_SPANS) == "table" then
    for _, span in ipairs(ctx.KONG_SPANS) do
      tablepool.release("kong_span", span)
    end
    tablepool.release("kong_spans", ctx.KONG_SPANS)
  end
end

function _M.init(config)
  local trace_types = config.instrumentation_trace_types
  local enabled = config.instrumentation_trace == true
  local sampling_rate = config.instrumentation_trace_sampling_rate
  if not enabled or type(trace_types) ~= "table" or sampling_rate <= 0 then
    return
  end

  if trace_types[1] == "all" then
    for typ, func in pairs(instrumentations) do
      _M[typ] = func
    end
  end

  for _, typ in ipairs(trace_types) do
    local func = instrumentations[typ]
    if func ~= nil then
      _M[typ] = func
    end
  end

  instrument_tracer = pdk_tracer.new("instrument", {
    sampling_rate = sampling_rate,
  })
  instrument_tracer.set_global_tracer(instrument_tracer)
end

return setmetatable(_M, noop_mt)
