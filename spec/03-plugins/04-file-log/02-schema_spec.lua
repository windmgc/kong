local Schema = require("kong.db.schema")

local IMMUTABLE_PATH = "/tmp/"

local ERR_MSG_INVLID_FILENAME =
  string.format("not a valid file name, "
              .. "or the prefix is not [%s], "
              .. "or contains `..`, "
              .. "you may need to check the configuration "
              .. "`plugin_file_log_immutable_path`",
                 IMMUTABLE_PATH)

insulate("Plugin: file-log (schema)", function()
  local tests = {
    {
      name = "path is required",
      input = {
        reopen = true,
      },
      output = nil,
      error = {
        config = {
          path = "required field missing",
        },
      },
    },
    ----------------------------------------
    {
      name = "rejects invalid filename",
      input = {
        path = "/ovo*",
        reopen = true,
      },
      output = nil,
      error = {
        config = {
          path = ERR_MSG_INVLID_FILENAME,
        },
      },
    },
    ----------------------------------------
    {
      name = "avoid path traversal attack",
      input = {
        path = "/tmp/../etc/passwd",
        reopen = true,
      },
      output = nil,
      error = {
        config = {
          path = ERR_MSG_INVLID_FILENAME,
        },
      },
    },
    ----------------------------------------
    {
      name = "reject filename without the correct prefix",
      input = {
        path = "/error-prefix/log.txt",
        reopen = true,
      },
      output = nil,
      error = {
        config = {
          path = ERR_MSG_INVLID_FILENAME,
        },
      },
    },
    ----------------------------------------
    {
      name = "accepts valid filename",
      input = {
        path = "/tmp/log.txt",
        reopen = true,
      },
      output = true,
      error = nil,
    },
    ----------------------------------------
    {
      name = "accepts custom fields set by lua code",
      input = {
        path = "/tmp/log.txt",
        custom_fields_by_lua = {
          foo = "return 'bar'",
        },
      },
      output = true,
      error = nil,
    },
  }

  local file_log_schema

  lazy_setup(function()
    _G.kong = {
      configuration = {
        untrusted_lua = "sandbox",
        plugin_file_log_immutable_path = IMMUTABLE_PATH,
      }
    }

    file_log_schema = Schema.new(require("kong.plugins.file-log.schema"))
  end)

  for _, t in ipairs(tests) do
    it(t.name, function()
      local output, err = file_log_schema:validate({
        protocols = { "http" },
        config = t.input
      })
      assert.same(t.error, err)
      assert.same(t.output, output)
    end)
  end
end)


insulate("Plugin: file-log (schema)", function()
  local tests = {
    {
      name = "reject filename without the default prefix",
      input = {
        path = "/error-prefix/log.txt",
        reopen = true,
      },
      output = nil,
      error = {
        config = {
          path = "not a valid file name, "
              .. "or the prefix is not [/kong/logs/], "
              .. "or contains `..`, "
              .. "you may need to check the configuration "
              .. "`plugin_file_log_immutable_path`",
        },
      },
    },
  }

  local file_log_schema

  lazy_setup(function()
    _G.kong = {
      configuration = {
        untrusted_lua = "sandbox",
        prefix = "/kong",
        plugin_file_log_immutable_path = nil,
      }
    }

    file_log_schema = Schema.new(require("kong.plugins.file-log.schema"))
  end)

  for _, t in ipairs(tests) do
    it(t.name, function()
      local output, err = file_log_schema:validate({
        protocols = { "http" },
        config = t.input
      })
      assert.same(t.error, err)
      assert.same(t.output, output)
    end)
  end
end)
