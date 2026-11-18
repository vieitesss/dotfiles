-- Minimal server config for the native picker integration tests.
package.path = os.getenv("REX_CONFIG_DIR") .. "/?.lua;" .. package.path
require("sessions")

-- Keep real config-action routing and server RPCs, but choose the sandbox's
-- local project without an app. Native prompting is tested separately.
rex.action{
  name = "rex_sessions_select_test",
  title = "Select sandbox project",
  run = function()
    local pick, servers = rex.ui.pick, rex.servers
    rex.ui.pick = function(prompt)
      -- After the first run the project is a merged session item.
      for _, item in ipairs(prompt.items) do
        if item.title == "personal/demo.app" and item.detail == "mac" then return item.id end
      end
      error("sandbox project missing from picker", 0)
    end
    -- No foreign app proxies this test's remote context. Keep this case
    -- focused on local session creation/reuse instead of proxy timeouts.
    rex.servers = function() return {} end
    local _, err = rex.invoke("rex_sessions")
    rex.ui.pick, rex.servers = pick, servers
    if err ~= nil then error(err, 0) end
  end,
}
