local table = table
local pack = table.pack
local unpack = table.unpack
local pdk_tracer = require "kong.pdk.tracer".new()


local _M = {}
local noop_mt = {
  __index = function ()
    return function () end
  end
}


local instrument_tracer = pdk_tracer.new("global")


local wrap_func
do
  local wrap_mt = {
    __call = function (self, ...)
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


-- db query
function instrumentations.db_query(connector)
  local f = connector.query

  local function wrap(self, sql, ...)
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


function _M.init(config)
  local trace_types = config.instrumentation_trace_types
  if type(trace_types) ~= "table" then
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


return setmetatable(_M, noop_mt)