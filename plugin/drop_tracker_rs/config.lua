-- Boss/item names MUST match the keys in rare_drops.json.
return {
  -- Must equal urls.api in plugin.json (no trailing slash). Use https in production.
  api_url = "http://127.0.0.1:8000",
  -- There is no settings UI wired up yet; set true to publish stats on the website under your in-game name.
  publish_to_website = false,
  -- Real wording (seen in game): "You have killed 48 Ivar, King of Bones in normal mode."
  -- Other bosses may word it differently; add a pattern per format. kc_first = kill count is the first capture.
  kill_patterns = {
    { pattern = "^You have killed ([%d,]+) (.-) in %a+ mode%.?$", kc_first = true },
  },
  -- Real wording (seen in game): "News: Silly Sour has received Ivar's loincloth drop at 54 kills!"
  -- Captures: player name, item name, kill count. The boss is worked out from the item.
  drop_patterns = {
    "^News: (.-) has received (.-) drop at ([%d,]+) kills?!?$",
  },
  -- Only these items are ever sent, so unrelated loot never leaves the client.
  --   items:    exact in-game name -> name to report
  --   patterns: Lua patterns for families of uniques
  tracked = {
    ["Har-Aken"] = { items = { ["Volcanic shard"] = "Shrimpy" } },
    ["Ivar, King of Bones"] = {
      items = {
        ["Bonecrusher maul"] = "Bonecrusher maul", ["Magic skull mask"] = "Magic skull mask",
        ["Ivar's loincloth"] = "Ivar's loincloth", ["Ivar's head"] = "Ivar's head",
      },
    },
    ["Telos, the Warden"] = {
      items = {
        ["Telos' sword"] = "Telos' sword", ["Telos' tendril"] = "Telos' tendril",
        ["Orb of pure anima"] = "Anima orb", ["Orb of volcanic anima"] = "Anima orb",
        ["Orb of corrupted anima"] = "Anima orb",
        ["Dormant Seren godbow"] = "Dormant Seren godbow", ["Dormant staff of Sliske"] = "Dormant staff of Sliske",
        ["Dormant Zaros godsword"] = "Dormant Zaros godsword", ["Reprisal ability codex"] = "Reprisal ability codex",
      },
    },
    ["Arch-Glacor"] = {
      items = {
        ["Leng artefact"] = "Leng artefact", ["Scripture of Wen"] = "Scripture of Wen",
        ["Frozen core of Leng"] = "Frozen core of Leng",
      },
    },
    ["Zamorak, Lord of Chaos"] = {
      items = {
        ["Codex of lost knowledge"] = "Codex of lost knowledge", ["Chaos Roar ability codex"] = "Chaos Roar ability codex",
        ["Vestments of havoc hood"] = "Vestments of havoc hood", ["Vestments of havoc robe top"] = "Vestments of havoc robe top",
        ["Vestments of havoc robe bottom"] = "Vestments of havoc robe bottom", ["Vestments of havoc boots"] = "Vestments of havoc boots",
        ["Top of the Last Guardian's bow"] = "Top of the Last Guardian's bow", ["Divine bowstring"] = "Divine bowstring",
        ["Bottom of the Last Guardian's bow"] = "Bottom of the Last Guardian's bow",
        ["Jewels of Zamorak"] = "Jewels of Zamorak", ["Zamorak's Edict runes"] = "Zamorak's Edict runes",
      },
    },
    ["The Barrows: Rise of the Six"] = {
      items = {
        ["Malevolent kiteshield"] = "Malevolent kiteshield", ["Merciless kiteshield"] = "Merciless kiteshield",
        ["Vengeful kiteshield"] = "Vengeful kiteshield", ["Rise of the Six chest"] = "Rise of the Six chest",
      },
    },
    ["The Barrows Brothers"] = {
      patterns = {
        "^Ahrim's ", "^Dharok's ", "^Guthan's ", "^Karil's ",
        "^Torag's ", "^Verac's ", "^Akrisae's ", "^Linza's ",
      },
    },
  },
}
