local base = require "resty.core.base"
local pack = table.pack
local unpack = table.unpack
local pdk_tracer = require "kong.pdk.tracer".new()


local _M = {}
local nop_mt = {
  __index = function ()
    return function () end
  end
}

local noop_tracer = pdk_tracer.new("instrument", { noop = true })


-- get tracer from context
local function get_tracer()
  if not base.get_quest() then
    return noop_tracer
  end

  local span = pdk_tracer.active_span()
  if not span then
    return noop_tracer
  end

  return span.tracer
end
_M.tracer = get_tracer


local wrap_func
do
  local wrap_mt = {
    __call = function (self, ...)
      local span = get_tracer().start_span(self.name)
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


-- db query
function instrumentations.db_query(connector)
  local f = connector.query

  local function wrap(self, sql, ...)
    local span = get_tracer().start_span("query")
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


function _M.init()
  if not kong then
    return -- testing env
  end

  local trace_types = kong.configuration.instrumentation_trace_types
  if trace_types ~= "table" or not next(trace_types) then
    return
  end

  if trace_types[1] == "all" then
    for typ, func in pairs(instrumentations) do
      _M[typ] = func
    end

    return
  end

  for _, typ in ipairs(trace_types) do
    local func = instrumentations[typ]
    if func ~= nil then
      _M[typ] = func
    end
  end

end


return setmetatable(_M, nop_mt)