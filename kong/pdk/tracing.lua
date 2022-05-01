---
-- Tracer module
--
-- Application-level tracing for Kong.
--
-- @module kong.tracing

local require = require
local ffi = require "ffi"
local bit = require "bit"
local tablepool = require "tablepool"
local new_tab = require "table.new"
local base = require "resty.core.base"
local utils = require "kong.tools.utils"
local phase_checker = require "kong.pdk.private.phases"

local ngx                = ngx
local error              = error
local setmetatable       = setmetatable
local rand_bytes         = utils.get_rand_bytes
local lshift             = bit.lshift
local rshift             = bit.rshift
local check_phase        = phase_checker.check
local PHASES             = phase_checker.phases
local ffi_time_unix_nano = utils.time_ns
local ffi_cast           = ffi.cast
local ffi_str            = ffi.string


local FLAG_SAMPLED = 0x01
local FLAG_RECORDING = 0x02
local FLAG_SAMPLED_AND_RECORDING = bit.bor(FLAG_SAMPLED, FLAG_RECORDING)

local SPAN_KIND = {
  UNSPECIFIED = 0,
  INTERNAL = 1,
  SERVER = 2,
  CLIENT = 3,
  PRODUCER = 4,
  CONSUMER = 5,
}

--- Generate trace ID
-- TODO(mayo): multiple ID generator
local function generate_trace_id()
  return rand_bytes(16)
end

--- Generate span ID
local function generate_span_id()
  return rand_bytes(8)
end

--- Build-in sampler
local function always_on_sampler()
  return FLAG_SAMPLED_AND_RECORDING
end

local function always_off_sampler()
  return 0
end

-- Fractions >= 1 will always sample. Fractions < 0 are treated as zero.
-- spec: https://github.com/c24t/opentelemetry-specification/blob/3b3d321865cf46364bdfb292c179b6444dc96bf9/specification/sdk-tracing.md#probability-sampler-algorithm
local function get_trace_id_based_sampler(fraction)
  if type(fraction) ~= "number" then
    error("invalid fraction", 2)
  end

  if fraction >= 1 then
    return always_on_sampler
  end

  if fraction <= 0 then
    return always_off_sampler
  end

  local upper_bound = fraction * tonumber(lshift(ffi_cast("uint64_t", 1), 63))

  return function(trace_id)
    local n = ffi_cast("uint64_t*", ffi_str(trace_id, 8))[0]
    n = rshift(n, 1)
    return tonumber(n) < upper_bound
  end
end


--- Span
-- @section span
local span_mt = {}
span_mt.__index = span_mt

-- Noop Span
local noop_span = {}
-- Using static function instead of metatable.__index for better performance
noop_span.is_recording = false
noop_span.finish = function() end
noop_span.set_attribute = function() end
noop_span.add_event = function() end
noop_span.record_error = function() end
noop_span.set_status = function() end
-- Avoid noop span table being modifed
setmetatable(noop_span, {
  __newindex = function() end,
})

local function new_span(tracer, name, options)
  if tracer == nil then
    error("invalid tracer", 2)
  end

  if type(name) ~= "string" or #name == 0 then
    error("invalid span name", 2)
  end

  if options ~= nil and type(options) ~= "table" then
    error("invalid options type", 2)
  end

  if options ~= nil then
    if options.start_time_ns ~= nil and type(options.start_time_ns) ~= "number" then
      error("invalid start time", 2)
    end

    if options.span_kind ~= nil and type(options.span_kind) ~= "number" then
      error("invalid start kind", 2)
    end

    if options.sampled ~= nil and type(options.sampled) ~= "boolean" then
      error("invalid sampled", 2)
    end

    if options.attributes ~= nil and type(options.attributes) ~= "table" then
      error("invalid attributes", 2)
    end
  end

  options = options or {}

  -- get parent span from ctx
  -- the ctx could either be stored in ngx.ctx or kong.ctx
  local parent_span = options.parent or tracer.active_span()

  local trace_id = parent_span and parent_span.trace_id
    or options.trace_id
    or generate_trace_id()

  local sampled = parent_span and parent_span.sampled
    or options.sampled
    or tracer.sampler(trace_id) == FLAG_SAMPLED_AND_RECORDING

  if not sampled then
    return noop_span
  end

  -- avoid reallocate
  -- we will release the span table at the end of log phase
  local span = tablepool.fetch("KONG_SPAN", 0, 12)
  -- cache tracer ref, to get hooks / span processer
  -- tracer ref will not be cleared when the span table released
  span.tracer = tracer

  span.name = name
  span.trace_id = trace_id
  span.span_id = generate_span_id()
  span.parent_id = parent_span and parent_span.span_id
      or options.parent_id

  -- specify span start time manually
  span.start_time_ns = options.start_time_ns or ffi_time_unix_nano()
  span.kind = options.kind or SPAN_KIND.INTERNAL
  span.attributes = options.attributes

  -- indicates whether the span should be reported
  span.sampled = parent_span and parent_span.sampled
      or options.sampled
      or sampled

  -- TODO(mayo): span.is_recording

  span.parent = parent_span

  setmetatable(span, span_mt)

  -- insert the span to ctx
  local spans = ngx.ctx.KONG_SPANS
  if not spans then
    spans = tablepool.fetch("KONG_SPANS", 10, 0)
    spans[0] = 0
    ngx.ctx.KONG_SPANS = spans
  end

  local len = spans[0] + 1
  spans[len] = span
  spans[0] = len

  return span
end

--- Ends a Span
--
-- @module Span
-- @tparam number|nil end_time_ns
function span_mt:finish(end_time_ns)
  if self.end_time_ns ~= nil then
    -- span is finished, and processed already
    return
  end

  if end_time_ns ~= nil and type(end_time_ns) ~= "number" then
    error("invalid span end time", 2)
  end

  if end_time_ns and end_time_ns < self.start_time_ns then
    error("invalid span duration", 2)
  end

  self.end_time_ns = end_time_ns or ffi_time_unix_nano()

  if self.active and self.tracer.active_span() == self then
    self.tracer.set_active_span(self.parent)
    self.active = nil
  end
end

--- Set an attribute to a Span
--
-- @module Span
-- @tparam string key
-- @tparam string|number|boolean value
function span_mt:set_attribute(key, value)
  if type(key) ~= "string" then
    error("invalid key", 2)
  end

  local vtyp = type(value)
  if vtyp ~= "string" and vtyp ~= "number" and vtyp ~= "boolean" then
    error("invalid value", 2)
  end

  if self.attributes == nil then
    self.attributes = new_tab(0, 4)
  end

  self.attributes[key] = value
end

-- Adds an event to a Span
--
-- @module Span
-- @tparam string name Event name
-- @tparam number|nil time_ns Event timestamp
-- @tparam number|nil attributes attributes
function span_mt:add_event(name, attributes, time_ns)
  if type(name) ~= "string" then
    error("invalid name", 2)
  end

  if attributes ~= nil then
    if type(attributes) ~= "table" then
      error("invalid attribute", 2)
    end
  end

  if self.events == nil then
    self.events = new_tab(4, 0)
    self.events[0] = 0
  end

  local obj = new_tab(0, 3)
  obj.name = name
  obj.time_ns = time_ns or ffi_time_unix_nano()
  if attributes then
    obj.attributes = attributes
  end

  -- cache table length to avoid calling `luaH_getn`
  local len = self.events[0] + 1
  self.events[len] = obj
  self.events[0] = len
end

-- Adds an error event to a Span
--
-- @module Span
-- @tparam string err error string
function span_mt:record_error(err)
  if type(err) ~= "string" then
    err = tostring(err)
  end

  self:add_event("exception", {
    ["exception.message"] = err,
  })
end

-- Adds an error event to a Span
--
-- @module Span
-- @tparam number status status code, 0 unset, 1 ok, 2 error
function span_mt:set_status(status)
  if type(status) ~= "number" then
    error("invalid status", 2)
  end

  self.status = status
end


--- Tracer
-- @section tracer
local tracer_mt = {}
tracer_mt.__index = tracer_mt


local tracer_cache = setmetatable({}, { __mode = "k" })

local noop_tracer = {}
noop_tracer.name = "noop"
noop_tracer.start_span = function() return noop_span end
noop_tracer.active_span = function() end
noop_tracer.set_active_span = function() end
noop_tracer.process_span = function() end

--- New Tracer
local function new_tracer(name, options)
  name = name or "default"

  if tracer_cache[name] then
    return tracer_cache[name]
  end

  local self = {
    name = name, -- Instrumentation library name
  }

  options = options or {}
  if options.noop then
    return noop_tracer
  end

  options.sampling_rate = options.sampling_rate or 1.0
  self.sampler = get_trace_id_based_sampler(options.sampling_rate)
  self.active_span_key = name .. "_" .. "active_span"

  --- Get the active span
  -- Returns the root span by default
  --
  -- @function kong.tracing.new_span
  -- @phases rewrite, access, header_filter, response, body_filter, log, admin_api
  -- @treturn table span
  function self.active_span()
    if not base.get_request() then
      return
    end

    return ngx.ctx[self.active_span_key]
  end

  --- Set the active span
  --
  -- @function kong.tracing.new_span
  -- @phases rewrite, access, header_filter, response, body_filter, log, admin_api
  -- @tparam table span
  function self.set_active_span(span)
    if not base.get_request() then
      return
    end

    if span then
      span.active = true
    end

    ngx.ctx[self.active_span_key] = span
  end

  --- Create a new Span
  --
  -- @function kong.tracing.new_span
  -- @phases rewrite, access, header_filter, response, body_filter, log, admin_api
  -- @tparam string name span name
  -- @tparam table options TODO(mayo)
  -- @treturn table span
  function self.start_span(...)
    if not base.get_request() then
      return noop_span
    end

    return new_span(self, ...)
  end

  --- Batch process spans
  -- Please note that socket is not available in the log phase, use `ngx.timer.at` instead
  --
  -- @function kong.tracing.process_span
  -- @phases log
  -- @tparam function processor a function that accecpt a span as the parameter
  function self.process_span(processor)
    check_phase(PHASES.log)

    if type(processor) ~= "function" then
      error("processor must be a function", 2)
    end

    if not ngx.ctx.KONG_SPANS then
      return
    end

    for _, span in ipairs(ngx.ctx.KONG_SPANS) do
      if span.tracer.name == self.name then
        processor(span)
      end
    end
  end

  tracer_cache[name] = setmetatable(self, tracer_mt)
  return tracer_cache[name]
end

tracer_mt.new = new_tracer
noop_tracer.new = new_tracer

local global_tracer
tracer_mt.set_global_tracer = function(tracer)
  if type(tracer) ~= "table" or getmetatable(tracer) ~= tracer_mt then
    error("invalid tracer", 2)
  end

  tracer.active_span_key = "active_span"
  global_tracer = tracer
  -- replace kong.pdk.tracer
  if kong then
    kong.tracing = tracer
  end
end
noop_tracer.set_global_tracer = tracer_mt.set_global_tracer
global_tracer = new_tracer("core", { noop = true })

tracer_mt.__call = function(_, ...)
  return new_tracer(...)
end
setmetatable(noop_tracer, {
  __call = tracer_mt.__call,
  __newindex = function () end
})

return {
  new = function()
    return global_tracer
  end,
}
