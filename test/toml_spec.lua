local toml = require("crates.toml")

describe("parse_crate_features", function()
    it("parses single line features", function()
        local text = '"derive", "alloc"'
        local features = toml.parse_crate_features(text)
        
        assert.equals(2, #features)
        assert.equals("derive", features[1].name)
        assert.equals("alloc", features[2].name)
    end)
    
    it("parses multiline features", function()
        local text = '"net",\n    "rt",\n    "macros"'
        local features = toml.parse_crate_features(text)
        
        assert.equals(3, #features)
        assert.equals("net", features[1].name)
        assert.equals("rt", features[2].name)
        assert.equals("macros", features[3].name)
    end)
    
    it("parses features with trailing comma", function()
        local text = '"derive", "alloc",'
        local features = toml.parse_crate_features(text)
        
        assert.equals(2, #features)
        assert.equals("derive", features[1].name)
        assert.equals("alloc", features[2].name)
        assert.is_true(features[2].comma)
    end)
end)
