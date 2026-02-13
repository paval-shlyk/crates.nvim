local toml = require("crates.toml")

describe("parse_crates multiline mixed", function()
    it("parses inline table with multiline features followed by other keys", function()
        local lines = {
            '[dependencies]',
            'dep = { features = [',
            '    "feat1"',
            '], version = "1.2.3" }'
        }
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        
        local _, crates = toml.parse_crates(buf)
        
        assert.equals(1, #crates)
        local crate = crates[1]
        assert.equals("dep", crate:package())
        assert.is_not_nil(crate.feat)
        assert.equals("feat1", crate.feat.items[1].name)
        
        -- This is the critical check: did we parse the version after the features array?
        assert.is_not_nil(crate.vers)
        assert.equals("1.2.3", crate.vers.text)
    end)
end)
