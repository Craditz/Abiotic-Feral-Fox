-- Feral Fox external settings. Close the game before changing this file.
return {
    -- Initial species when player-option.txt does not exist: false = Human.
    -- Creation / the Fox tab saves the local Human/Fox choice for future sessions.
    auto_enable = false,
    -- F7 inspection camera; F3 / Shift+F3 animation previews; F2 distance.
    -- F9/F10 and Shift variants rotate/tilt the camera or keyboard look.
    inspection_controls = true,
    -- Optional diagnostic, species/eye-height and inventory test-kit controls.
    -- Normal play and inspection need no developer controls.
    developer_controls = false,
    -- Optional existing local vocals; public downloads contain no sounds. Native voice remains when unavailable.
    fox_voice = true,
    fox_voice_replace_scientist = true, -- Local character vocals only; restored for Human.
    fox_voice_volume = 2.0, -- 0..2; internally matched clip peaks before this gain.
    fox_voice_idle_min_seconds = 90,
    fox_voice_idle_max_seconds = 180,
    fox_voice_hurt_cooldown_seconds = 3,
    fox_voice_combat_chance = 0.15, -- Occasional native unarmed attack only.
    fox_voice_combat_cooldown_seconds = 12,
    -- Experimental, standalone only. False keeps the game's human collision.
    -- WARNING: changing species or disabling this setting in a fox-only gap
    -- may get you stuck; leave the gap first or use the game's Unstuck option.
    small_collision = true,
    -- Uniform actor scale preserves native crouch/uncrouch capsule defaults.
    -- 0.375 gives a standing capsule about 72 cm tall and 24 cm across;
    -- crouching gives about 45 cm height. The visible fox keeps its size.
    collision_scale = 0.375,
    -- Cosmetic mouth grip. Native tools, firing, reloading and item effects remain active.
    mouth_items = true,
    mouth_item_scale = 1,
    -- Briefly hide the cosmetic item while native equip fields settle (0..250 ms).
    mouth_swap_delay_ms = 80,
    -- Third-person Jaw-bone grip, in world cm along the animated bone axes.
    -- X right, Y forward, Z up. Yaw 90 points ordinary weapon X along the muzzle.
    mouth_grip = {location={X=0,Y=8,Z=5},rotation={Pitch=0,Yaw=90,Roll=0}},
    -- Rough sideways bite for the two tested pistols. Other items use mouth_grip.
    mouth_grips = {
        pistol_security={location={X=0,Y=5,Z=2},rotation={Pitch=0,Yaw=90,Roll=90}},
        pistol_pipe={location={X=0,Y=5,Z=2},rotation={Pitch=0,Yaw=90,Roll=90}},
        food_chips={location={X=0,Y=5,Z=2},rotation={Pitch=0,Yaw=90,Roll=0},scale=0.45},
    },
    -- Camera-local forward/right/up offset; intentionally keeps the center clear.
    mouth_first_person_cm = {X=24,Y=8,Z=-12},
}
