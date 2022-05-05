local typedefs = require "kong.db.schema.typedefs"

local path_prefix = kong.configuration.plugin_file_log_immutable_path

if not path_prefix then
  path_prefix = kong.configuration.prefix .. "/logs/"
end

if string.sub(path_prefix, -1) ~= "/" then
  path_prefix = path_prefix .. "/"
end

local path_pattern = string.format([[^%s[^*&%%\`]+$]], path_prefix)

local err_msg = 
  string.format("not a valid file name, "
              .. "or the prefix is not [%s], "
              .. "or contains `..`",
                path_prefix)


return {
  name = "file-log",
  fields = {
    { protocols = typedefs.protocols },
    { config = {
        type = "record",
        fields = {
          { path = { type = "string",
                     required = true,
                     match = path_pattern,
                     -- to avoid the path traversal attack
                     not_match = [[%.%.]],
                     err = err_msg,
          }, },
          { reopen = { type = "boolean", required = true, default = false }, },
          { custom_fields_by_lua = typedefs.lua_code },
        },
    }, },
  }
}
