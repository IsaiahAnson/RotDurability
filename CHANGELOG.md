# Changelog

## 2.6.0 — first public release

Durability shown as **uses remaining** instead of a percentage, plus a **DPS**
figure on the damage row.

The version number starts at 2.6.0 because that is what the mod reports in its
own log, and having the listing disagree with the log would only make bug
reports harder to read.

### Durability

- Durability reads `47 / 60 uses` instead of `100%`, so two weapons on a shop
  shelf can finally be compared.
- Per-use costs for the base game's weapons ship with the mod, so the numbers
  are correct on a fresh save, in a shop, before buying anything.
- Costs for anything else are learned three ways: from a shop's own item data,
  or by watching durability fall as you use a weapon — which covers dungeon
  loot that shops never sell.
- Weapons learned by use are named properly once you inspect them, so the saved
  data ends up readable rather than full of internal asset names.
- A weapon whose cost genuinely is not known yet shows honest durability
  **points**, never a guessed use count.

### DPS

- Damage per second on the damage row, from the weapon's real attack cadence.
- Guns read their fire rate directly, so DPS is exact and appears without ever
  firing a shot. Multi-projectile weapons count every pellet — a shotgun listed
  as `5-8` firing five of them is shown as `5-8 x5`.
- Melee attack speed is timed from real swings and converges on the weapon's
  true cadence. Estimates only ever tighten, so the figure stops drifting
  between sessions once it settles.
- Attack speeds for the base game's weapons ship with the mod, so most weapons
  show DPS immediately.
- Enchantment damage is read live off the individual item, so Blazing, Infested
  and Reinforced variants each show their own DPS with no setup.
- **Demolition Power is excluded** — it only applies to breakable scenery, and
  including it would make the number useless for comparing weapons.
- Sustained-fire weapons keep showing points, because "uses" is not a real unit
  for something that drains continuously.

### Behaviour

- Client-side and cosmetic. Only text in your own inspect panel is rewritten.
  No gameplay values change, and multiplayer is unaffected whether or not other
  players run it.
- Furniture, character and treasure inspect panels are left untouched.
- Learned data persists between sessions in two plain-text files under
  `%LOCALAPPDATA%\Helden\Saved\`, both safe to delete.
