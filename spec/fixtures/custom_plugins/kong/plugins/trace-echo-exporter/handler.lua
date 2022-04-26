local cjson = require "cjson"
local inspect = require "inspect"

local ngx = ngx
local kong = kong
local table = table
local insert = table.insert


local _M = {
  PRIORITY = 1001,
}


local tracer_cache = setmetatable({}, { __mode = "k" })


local function exporter(span)
  if not ngx.ctx.span_store then
    ngx.ctx.span_store = {}
  end

  local copy = table.clone(span)
  copy.tracer = nil

  --print(inspect(copy))

  insert(ngx.ctx.span_store, copy)
end


local function get_tracer(config)
  local tracer = tracer_cache[config]
  if not tracer then
    tracer = kong.tracer.new("trace-echo-exporter", { exporter = exporter })
    -- cache tracer
    tracer_cache[config] = tracer
  end

  return tracer
end


function _M:rewrite(config)
  local tracer = get_tracer(config)

  tracer.start_span("rewrite")
end


function _M:access(config)
  local tracer = get_tracer(config)

  local span = tracer.start_span("access")
  span:finish()
end


function _M:log(config)
  local tracer = get_tracer(config)
  local span = tracer.active_span()

  if span then
    --print(inspect(span))
    span:finish()
  end

  local data = cjson.encode(ngx.ctx.span_store)
  print(data)

  local function push_data(_, data)
    local tcpsock = ngx.socket.tcp()
    local ok, err = tcpsock:connect("127.0.0.1", 8189)
    if not ok then
      kong.log.err("connect err: ".. err)
      return
    end
    tcpsock:settimeout(1000)
    local _, err = tcpsock:send(data)
    if err then
      kong.log.err(err)
    end
    tcpsock:close()

    kong.log.notice("sent")
  end

  local ok, err = ngx.timer.at(0, push_data, data)
  if not ok then
    kong.log.err(err)
  end
end


return _M
