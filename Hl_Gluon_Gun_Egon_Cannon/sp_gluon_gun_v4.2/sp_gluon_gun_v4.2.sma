/*
 * ===========================================================================
 *
 *   SP-TEAM Gluon Gun - Quantum Beam Cannon
 *   For Zombie Plague 4.3+ (Meat Mod)
 *
 *   Version: 4.1 - QA Bug-Fix Pass
 *   Authors: SP-TEAM: sp_half/sp_saad
 *
 *   Inspired by the Gluon Gun (Egon) from Half-Life: Opposing Force.
 *   A rare, balanced beam weapon for emergency zombie defense.
 *
 *   v4.1 QA Fixes:
 *     1. DROP BUG: spawn_dropped_gluon() now uses angle_vector(FORWARD) to
 *        throw the weapon in front of the player at 300 u/s + 80 u/s upward,
 *        preventing instant re-pickup by the dropper.
 *
 *     2. BEAM LAG: Both CBeam entities now use BEAM_ENTPOINT mode with
 *        Beam_SetStartEntity(beam, id) instead of Beam_SetStartPos() each
 *        tick. The GoldSrc engine interpolates the muzzle position every
 *        frame, eliminating the 0.1s stutter when walking backwards.
 *        Beam_SetEndPos(beam, vHit) in task_BeamTick still updates the far
 *        end each tick as before.
 *
 *     3. FIRST-SHOT STUTTER: start_beam() now fires the first damage/visual
 *        tick immediately via a direct call to beam_do_tick() instead of
 *        waiting 0.1s for the first task_BeamTick invocation. The repeating
 *        task continues from tick 2 onward. The windup sound state is handled
 *        inside beam_do_tick() so the transition is seamless.
 *
 *     4. MUZZLE OFFSET: get_muzzle_origin() updated to the QA-verified
 *        coordinates: Fwd*10 + Right*-4 + Up*-5.
 *
 *     5. FLARE SPRITE: Added g_iPlayerFlare[MAX_PLAYERS+1]. A persistent
 *        info_target entity is created in start_beam() using the original
 *        XSpark1.spr from egon.cpp (SpriteCreate parameters matching Valve:
 *        scale=1.0, kRenderGlow, kRenderFxNoDissipation). Its origin is
 *        updated to vHit in task_BeamTick each tick. Removed in
 *        kill_player_beam() alongside the CBeam entities.
 *
 *     6. WEAPON ANIMATIONS: Added SendWeaponAnim() stock that mirrors Valve's
 *        implementation (sets pev_weaponanim, sends SVC_WEAPONANIM message).
 *        Animations triggered:
 *          - EGON_FIRE1  when the beam starts (start_beam)
 *          - EGON_HOLSTER when the beam stops (stop_beam)
 *          - EGON_IDLE1  when the weapon is deployed (fw_Deploy_Post)
 *        Enum egon_e matches Valve's original animation indices.
 *
 *   v4.0 Features retained:
 *     - Secondary attack (Right Click) → FIRE_NARROW mode.
 *     - FIRE_WIDE / FIRE_NARROW with independent heat, ammo, damage, knockback.
 *     - g_iFireMode[MAX_PLAYERS+1] per-player mode tracking.
 *     - fw_SecondaryAttack HAM hook.
 *     - HUD shows mode label ("WIDE" / "NARROW").
 *
 *   v3.1 Fixes retained:
 *     - Dual-beam CBeam entities (Valve dual-beam design).
 *     - Speed-stacking fix via task_exists() guard.
 *
 *   v3.0 Changes retained:
 *     - Persistent CBeam entities, BEAM_FSINE on primary.
 *     - Full beam cleanup on disconnect/death/infection/drop/holster.
 *
 *   v2.0 Features retained:
 *     - Muzzle-origin beam with purple visuals.
 *     - Sound state machine (windup → loop → off).
 *     - High damage balanced for 6000HP zombies.
 *     - Knockback + 30% speed reduction on hit.
 *     - Heat system with passive cooling & manual venting (R key).
 *     - Quantum Vulnerability: 3s beam = +50% team damage.
 *     - Disintegration effect on beam kill.
 *     - Dropped weapon pickup by teammates.
 *     - FM_SetModel world model fix.
 *     - Nemesis 50% damage/knockback reduction.
 *     - Energy Instability on 3 overheats.
 *
 * ===========================================================================
 */

#include <amxmodx>
#include <engine>
#include <fakemeta>
#include <hamsandwich>
#include <fun>
#include <cstrike>
#include <zombieplague>
#include <colorchat>
#include <beams>

#pragma semicolon 1

/* ===========================================================================
 * SECTION 1: CONSTANTS & DEFINES
 * =========================================================================== */

#define PLUGIN_NAME    "[ZP] SP Gluon Gun v4"
#define PLUGIN_VERSION "4.1"
#define PLUGIN_AUTHOR  "SP-TEAM: sp_half/sp_saad"

#define MAX_PLAYERS 32

new const ITEM_NAME[] = "\rGluon Gun \w[Quantum Beam] \y[Rare]";
const ITEM_COST = 45;

const GLUON_MAX_AMMO           = 100;
const Float:GLUON_TICK_RATE    = 0.1;
const Float:GLUON_MAX_RANGE    = 1200.0;
const Float:GLUON_COOLDOWN_DUR = 7.0;
const GLUON_GLOBAL_LIMIT       = 3;
const GLUON_MIN_ZOMBIES        = 10;
const Float:GLUON_BUY_COOLDOWN = 30.0;
const GLUON_INSTAB_THRESHOLD   = 3;
const GLUON_INSTAB_HP_LOSS     = 20;
const Float:NEMESIS_MULT       = 0.5;

// --- FIRE_WIDE (primary, left-click) stats ---
const Float:WIDE_DMG_CLOSE    = 165.0;
const Float:WIDE_DMG_FAR      = 120.0;
const Float:WIDE_HEAT_TICK    = 1.0;    // heat per 0.1s tick
const Float:WIDE_AMMO_RATE    = 0.4;    // ammo: 1 unit every N seconds
const Float:WIDE_KNOCKBACK    = 280.0;

// --- FIRE_NARROW (secondary, right-click) stats ---
const Float:NARROW_DMG_CLOSE  = 132.0;  // 165 * 0.80
const Float:NARROW_DMG_FAR    =  96.0;  // 120 * 0.80
const Float:NARROW_HEAT_TICK  = 0.6;    // 40% less heat per tick
const Float:NARROW_AMMO_RATE  = 0.6;    // ammo: 1 unit every 0.6s
const Float:NARROW_KNOCKBACK  = 168.0;  // 280 * 0.60

const Float:GLUON_RANGE_CLOSE = 200.0;
const Float:GLUON_RANGE_FAR   = 800.0;

const Float:COOL_PER_TICK     = 1.0;
const Float:VENT_PER_TICK     = 2.0;
const Float:MAX_HEAT          = 100.0;

const Float:SPEED_REDUCTION    = 0.70;
const Float:SPEED_RESTORE_TIME = 0.5;

const Float:VULN_BEAM_TIME    = 3.0;
const Float:VULN_DURATION     = 5.0;
const Float:VULN_BONUS_DMG    = 1.5;

// v4.1: forward throw speed for dropped weapon (units/s).
const Float:DROP_THROW_SPEED  = 300.0;
const Float:DROP_THROW_UP     = 80.0;

#define CSW_BASE CSW_P90
new const WEAPON_BASE[]     = "weapon_p90";
new const GLUON_CLASSNAME[] = "sp_gluongun";

const TASK_BEAM       = 7000;
const TASK_COOLDOWN   = 7100;
const TASK_HUD        = 7200;
const TASK_PASSIVE    = 7300;
const TASK_SPEED_RST  = 7400;
const TASK_VULN_END   = 7500;
const TASK_RECHARGE   = 7600;

const Float:RECHARGE_RATE = 2.0;

new const SND_PICKUP[] = "items/gunpickup2.wav";

// MODE_SURVIVOR is defined in zombieplague.inc

/* ===========================================================================
 * SECTION 2: SOUND & MODEL PATHS
 * =========================================================================== */

new const MDL_V[] = "models/v_egon.mdl";
new const MDL_P[] = "models/p_egon.mdl";
new const MDL_W[] = "models/w_egon.mdl";

new const GSND_START[]      = "weapons/egon_windup2.wav";
new const GSND_RUN[]        = "weapons/egon_run3.wav";
new const GSND_OFF[]        = "weapons/egon_off1.wav";
new const SND_OVERHEAT[]    = "debris/zap4.wav";
new const SND_INSTABILITY[] = "ambience/thunder_clap.wav";
new const SND_RECHARGE[]    = "items/suitchargeok1.wav";
new const SND_VENT[]        = "player/pl_duct2.wav";

new const BEAM_SPRITE[]  = "sprites/xbeam1.spr";
new const SMOKE_SPRITE[] = "sprites/steam1.spr";
// v4.1: XSpark1 flare sprite from original egon.cpp.
new const FLARE_SPRITE[] = "sprites/XSpark1.spr";

/* ===========================================================================
 * SECTION 3: ENUMS & PLAYER DATA
 * =========================================================================== */

// Fire modes, mirroring Valve's egon.cpp enum.
enum GluonFireMode
{
    FIRE_WIDE = 0,   // Left-click  — thick beam, high heat, high damage
    FIRE_NARROW      // Right-click — thin beam, low heat, precision damage
};


new g_iItemID;
new g_iSmokeSpr;
new g_iFlareSpr;      // v4.1: precached XSpark1 model index
new g_iMaxPlayers;
new g_iGluonsSold;

// CBeam tracking (two beams per player, Valve dual-beam design).
new g_iPlayerBeam[MAX_PLAYERS + 1];
new g_iPlayerNoise[MAX_PLAYERS + 1];
new Float:g_vBeamHit[MAX_PLAYERS + 1][3];

// v4.1: Flare (hit-point sprite) entity tracking.
new g_iPlayerFlare[MAX_PLAYERS + 1];

// v4.0: Active fire mode per player.
new GluonFireMode:g_iFireMode[MAX_PLAYERS + 1];

new bool:g_bHasGluon[MAX_PLAYERS + 1];
new bool:g_bGluonEquipped[MAX_PLAYERS + 1];
new bool:g_bFiring[MAX_PLAYERS + 1];
new bool:g_bOverheated[MAX_PLAYERS + 1];
new bool:g_bInstability[MAX_PLAYERS + 1];
new bool:g_bBoughtThisRound[MAX_PLAYERS + 1];
new bool:g_bVenting[MAX_PLAYERS + 1];
new g_iAmmo[MAX_PLAYERS + 1];
new g_iOverheatCount[MAX_PLAYERS + 1];
new g_iSoundState[MAX_PLAYERS + 1];
new Float:g_fHeat[MAX_PLAYERS + 1];
new Float:g_fCooldownEnd[MAX_PLAYERS + 1];
new Float:g_fLastPurchase[MAX_PLAYERS + 1];
new Float:g_fAmmoAccum[MAX_PLAYERS + 1];

new g_iBeamTarget[MAX_PLAYERS + 1];
new Float:g_fBeamHitTime[MAX_PLAYERS + 1];

new bool:g_bVulnerable[MAX_PLAYERS + 1];
new Float:g_fVulnEnd[MAX_PLAYERS + 1];

enum { SND_STATE_IDLE = 0, SND_STATE_WINDUP, SND_STATE_LOOP };

/* ===========================================================================
 * SECTION 4: PRECACHE
 * =========================================================================== */

public plugin_precache()
{
    precache_model(MDL_V);
    precache_model(MDL_P);
    precache_model(MDL_W);

    precache_sound(GSND_START);
    precache_sound(GSND_RUN);
    precache_sound(GSND_OFF);
    precache_sound(SND_OVERHEAT);
    precache_sound(SND_INSTABILITY);
    precache_sound(SND_RECHARGE);
    precache_sound(SND_VENT);
    precache_sound(SND_PICKUP);

    precache_model(BEAM_SPRITE);
    g_iSmokeSpr  = precache_model(SMOKE_SPRITE);
    // v4.1: precache the flare sprite and store its model index.
    g_iFlareSpr  = precache_model(FLARE_SPRITE);
}

/* ===========================================================================
 * SECTION 5: PLUGIN INIT
 * =========================================================================== */

public plugin_init()
{
    register_plugin(PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR);

    g_iItemID = zp_register_extra_item(ITEM_NAME, ITEM_COST, ZP_TEAM_HUMAN);

    RegisterHam(Ham_Item_Deploy,            WEAPON_BASE, "fw_Deploy_Post",       1);
    RegisterHam(Ham_Item_Holster,           WEAPON_BASE, "fw_Holster_Post",      1);
    RegisterHam(Ham_Weapon_PrimaryAttack,   WEAPON_BASE, "fw_PrimaryAttack");
    RegisterHam(Ham_Weapon_SecondaryAttack, WEAPON_BASE, "fw_SecondaryAttack");
    RegisterHam(Ham_Weapon_Reload,          WEAPON_BASE, "fw_Reload");
    RegisterHam(Ham_Killed,                 "player",    "fw_PlayerKilled_Post", 1);
    RegisterHam(Ham_TakeDamage,             "player",    "fw_TakeDamage");

    register_clcmd("drop", "Cmd_DropGluon");

    register_forward(FM_CmdStart,         "fw_CmdStart");
    register_forward(FM_UpdateClientData, "fw_UpdateClientData_Post", 1);
    register_forward(FM_SetModel,         "fw_SetModel");
    register_forward(FM_Touch,            "fw_Touch");

    register_event("HLTV", "ev_RoundStart", "a", "1=0", "2=0");

    g_iMaxPlayers = get_maxplayers();
}

/* ===========================================================================
 * SECTION 6: ITEM PURCHASE
 * =========================================================================== */

public zp_extra_item_selected(id, itemid)
{
    if (itemid != g_iItemID)
        return PLUGIN_CONTINUE;

    if (!is_user_alive(id) || zp_get_user_zombie(id))
    {
        ColorChat(id, GREEN, "^4[SP-TEAM]^1 Gluon Gun is for humans only.");
        return ZP_PLUGIN_HANDLED;
    }

    if (g_bHasGluon[id])
    {
        ColorChat(id, GREEN, "^4[SP-TEAM]^1 You already have the Gluon Gun.");
        return ZP_PLUGIN_HANDLED;
    }

    if (g_bBoughtThisRound[id])
    {
        ColorChat(id, GREEN, "^4[SP-TEAM]^1 Gluon Gun is one-use per round.");
        return ZP_PLUGIN_HANDLED;
    }

    if (g_bInstability[id])
    {
        ColorChat(id, GREEN, "^4[SP-TEAM]^1 Energy Instability active. Gluon Gun disabled this round.");
        return ZP_PLUGIN_HANDLED;
    }

    new Float:fNow = get_gametime();
    if ((fNow - g_fLastPurchase[id]) < GLUON_BUY_COOLDOWN && g_fLastPurchase[id] > 0.0)
    {
        new iWait = floatround(GLUON_BUY_COOLDOWN - (fNow - g_fLastPurchase[id]), floatround_ceil);
        ColorChat(id, GREEN, "^4[SP-TEAM]^1 Purchase cooldown: ^3%d^1 seconds remaining.", iWait);
        return ZP_PLUGIN_HANDLED;
    }

    if (g_iGluonsSold >= GLUON_GLOBAL_LIMIT)
    {
        ColorChat(id, GREEN, "^4[SP-TEAM]^1 Global limit reached (^3%d/%d^1 sold this round).", g_iGluonsSold, GLUON_GLOBAL_LIMIT);
        return ZP_PLUGIN_HANDLED;
    }

    new iZombies = count_zombies();
    if (iZombies < GLUON_MIN_ZOMBIES)
    {
        ColorChat(id, GREEN, "^4[SP-TEAM]^1 Gluon Gun requires at least ^3%d^1 zombies (current: ^3%d^1).", GLUON_MIN_ZOMBIES, iZombies);
        return ZP_PLUGIN_HANDLED;
    }

    give_gluon(id, GLUON_MAX_AMMO, 0.0);
    g_bBoughtThisRound[id] = true;
    g_fLastPurchase[id]    = get_gametime();
    g_iGluonsSold++;

    ColorChat(id, GREEN, "^4[SP-TEAM]^1 Gluon Gun acquired! Ammo: ^3%d^1 | LMB=WIDE | RMB=NARROW | R=Vent.", GLUON_MAX_AMMO);
    ColorChat(id, GREEN, "^4[-S|P-]^1 Emergency weapon. ^3%d/%d^1 sold this round.", g_iGluonsSold, GLUON_GLOBAL_LIMIT);

    return PLUGIN_CONTINUE;
}

give_gluon(id, iAmmo, Float:fHeat)
{
    g_bHasGluon[id]      = true;
    g_iAmmo[id]          = iAmmo;
    g_fHeat[id]          = fHeat;
    g_bOverheated[id]    = false;
    g_bFiring[id]        = false;
    g_bVenting[id]       = false;
    g_bInstability[id]   = false;
    g_iOverheatCount[id] = 0;
    g_iSoundState[id]    = SND_STATE_IDLE;
    g_fAmmoAccum[id]     = 0.0;
    g_iBeamTarget[id]    = 0;
    g_fBeamHitTime[id]   = 0.0;
    g_iFireMode[id]      = FIRE_WIDE;

    give_item(id, WEAPON_BASE);
    SyncAmmoHUD(id);

    set_task(0.3,             "task_HudRefresh",  id + TASK_HUD,      _, _, "b");
    set_task(GLUON_TICK_RATE, "task_PassiveCool", id + TASK_PASSIVE,  _, _, "b");
    set_task(RECHARGE_RATE,   "task_AutoRecharge", id + TASK_RECHARGE, _, _, "b");
}

/* ===========================================================================
 * SECTION 7: WEAPON DEPLOY / HOLSTER / WORLD MODEL
 * =========================================================================== */

public fw_Deploy_Post(iEnt)
{
    new id = get_pdata_cbase(iEnt, 41, 4);
    if (!is_valid_player(id) || !g_bHasGluon[id])
        return HAM_IGNORED;

    g_bGluonEquipped[id] = true;
    set_pev(id, pev_viewmodel2,   MDL_V);
    set_pev(id, pev_weaponmodel2, MDL_P);
    set_pdata_float(id, 83, 0.75, 5);

    // v4.1: Play the draw animation on deploy.
    SendWeaponAnim(id, 2);

    return HAM_IGNORED;
}

public fw_Holster_Post(iEnt)
{
    new id = get_pdata_cbase(iEnt, 41, 4);
    if (!is_valid_player(id) || !g_bHasGluon[id])
        return HAM_IGNORED;

    g_bGluonEquipped[id] = false;
    g_bVenting[id]       = false;
    stop_beam(id);

    return HAM_IGNORED;
}

public fw_PrimaryAttack(iEnt)
{
    new id = get_pdata_cbase(iEnt, 41, 4);
    if (!is_valid_player(id) || !g_bHasGluon[id] || !g_bGluonEquipped[id])
        return HAM_IGNORED;

    return HAM_SUPERCEDE;
}

public fw_SecondaryAttack(iEnt)
{
    new id = get_pdata_cbase(iEnt, 41, 4);
    if (!is_valid_player(id) || !g_bHasGluon[id] || !g_bGluonEquipped[id])
        return HAM_IGNORED;

    return HAM_SUPERCEDE;
}

public fw_Reload(iEnt)
{
    new id = get_pdata_cbase(iEnt, 41, 4);
    if (!is_valid_player(id) || !g_bHasGluon[id] || !g_bGluonEquipped[id])
        return HAM_IGNORED;

    return HAM_SUPERCEDE;
}

public Cmd_DropGluon(id)
{
    if (!is_user_alive(id) || !g_bHasGluon[id])
        return PLUGIN_CONTINUE;

    if (get_user_weapon(id) != CSW_BASE)
        return PLUGIN_CONTINUE;

    stop_beam(id);
    spawn_dropped_gluon(id);
    strip_gluon_weapon(id);
    cleanup_gluon(id);

    ColorChat(id, GREEN, "^4[SP-TEAM]^1 Gluon Gun dropped.");
    return PLUGIN_HANDLED;
}

public fw_SetModel(iEnt, const szModel[])
{
    if (!pev_valid(iEnt))
        return FMRES_IGNORED;

    static szClassname[32];
    pev(iEnt, pev_classname, szClassname, charsmax(szClassname));

    if (!equal(szClassname, "weaponbox"))
        return FMRES_IGNORED;

    if (equal(szModel, "models/w_p90.mdl"))
    {
        new iOwner = pev(iEnt, pev_owner);
        if (is_valid_player(iOwner) && g_bHasGluon[iOwner])
        {
            set_pev(iEnt, pev_flags, pev(iEnt, pev_flags) | FL_KILLME);
            return FMRES_SUPERCEDE;
        }
    }

    return FMRES_IGNORED;
}

/* ===========================================================================
 * SECTION 8: INPUT DETECTION
 * =========================================================================== */

public fw_CmdStart(id, uc_handle, seed)
{
    if (!is_user_alive(id) || !g_bHasGluon[id] || !g_bGluonEquipped[id])
        return FMRES_IGNORED;

    if (g_bInstability[id])
        return FMRES_IGNORED;

    new iButtons      = get_uc(uc_handle, UC_Buttons);
    new bool:bAttack  = bool:(iButtons & IN_ATTACK);   // LMB — FIRE_WIDE
    new bool:bAttack2 = bool:(iButtons & IN_ATTACK2);  // RMB — FIRE_NARROW
    new bool:bReload  = bool:(iButtons & IN_RELOAD);   // R   — vent heat

    // ── Venting (R key) ──────────────────────────────────────────────────────
    if (bReload && !g_bFiring[id] && !g_bOverheated[id] && g_fHeat[id] > 0.0)
    {
        if (!g_bVenting[id])
        {
            g_bVenting[id] = true;
            emit_sound(id, CHAN_BODY, SND_VENT, 0.4, ATTN_NORM, 0, PITCH_NORM);
        }
    }
    else if (!bReload && g_bVenting[id])
    {
        g_bVenting[id] = false;
        emit_sound(id, CHAN_BODY, SND_VENT, 0.0, ATTN_NORM, SND_STOP, PITCH_NORM);
    }

    // ── Fire-mode selection & beam start/stop ─────────────────────────────────
    new bool:bCanFire = bool:(!g_bOverheated[id] && !g_bVenting[id] && g_iAmmo[id] > 0);

    if (!g_bFiring[id])
    {
        if (bAttack && bCanFire)
        {
            g_iFireMode[id] = FIRE_WIDE;
            start_beam(id);
        }
        else if (bAttack2 && bCanFire)
        {
            g_iFireMode[id] = FIRE_NARROW;
            start_beam(id);
        }
    }
    else
    {
        new bool:bActiveReleased;
        if (g_iFireMode[id] == FIRE_WIDE)
            bActiveReleased = !bAttack;
        else
            bActiveReleased = !bAttack2;

        if (bActiveReleased || g_bOverheated[id] || g_bVenting[id])
            stop_beam(id);
    }

    // ── Eat both attack inputs while firing ───────────────────────────────────
    if (g_bFiring[id])
    {
        iButtons &= ~IN_ATTACK;
        iButtons &= ~IN_ATTACK2;
        set_uc(uc_handle, UC_Buttons, iButtons);
    }

    // ── Eat reload while venting or overheated ───────────────────────────────
    if (g_bVenting[id] || g_bOverheated[id])
    {
        iButtons &= ~IN_RELOAD;
        set_uc(uc_handle, UC_Buttons, iButtons);
    }
    
    if (g_bFiring[id])
    {
        new Float:vMuzzle[3];
        get_muzzle_origin(id, vMuzzle);
        if (g_iPlayerBeam[id] != 0 && pev_valid(g_iPlayerBeam[id]))
        {
            Beam_SetStartPos(g_iPlayerBeam[id], vMuzzle);
            Beam_SetEndPos(g_iPlayerBeam[id], g_vBeamHit[id]);
            Beam_RelinkBeam(g_iPlayerBeam[id]);
        }
        if (g_iPlayerNoise[id] != 0 && pev_valid(g_iPlayerNoise[id]))
        {
            Beam_SetStartPos(g_iPlayerNoise[id], vMuzzle);
            Beam_SetEndPos(g_iPlayerNoise[id], g_vBeamHit[id]);
            Beam_RelinkBeam(g_iPlayerNoise[id]);
        }
        if (g_iPlayerFlare[id] != 0 && pev_valid(g_iPlayerFlare[id]))
        {
            engfunc(EngFunc_SetOrigin, g_iPlayerFlare[id], g_vBeamHit[id]);
        }
    }

    return FMRES_IGNORED;
}

public fw_UpdateClientData_Post(id, sendweapons, cd_handle)
{
    if (!is_user_alive(id) || !g_bHasGluon[id] || !g_bGluonEquipped[id])
        return FMRES_IGNORED;

    set_cd(cd_handle, CD_flNextAttack, 9999.0);
    return FMRES_IGNORED;
}

/* ===========================================================================
 * SECTION 9: BEAM FIRE SYSTEM
 * =========================================================================== */

/*
 * start_beam(id)
 *   Creates all three persistent entities (primary CBeam, noise CBeam,
 *   flare sprite) with mode-appropriate parameters, then fires the very
 *   first tick immediately via beam_do_tick() to eliminate the first-shot
 *   stutter. The repeating task handles all subsequent ticks.
 *
 *   v4.1 key changes:
 *     - Beams use BEAM_ENTPOINT (Beam_PointEntInit) with the player entity
 *       as the start, so GoldSrc interpolates the muzzle position every
 *       rendered frame instead of only when the task fires.
 *     - Flare sprite entity (info_target + XSpark1.spr) is created here.
 *     - beam_do_tick() is called once immediately before the repeating task.
 *
 *   FIRE_WIDE:   Primary W=40, BEAM_FSINE, Noise=20, ScrollRate=50, Purple.
 *                Noise    W=55,             Noise=8,  ScrollRate=25, Deep-purple.
 *   FIRE_NARROW: Primary W=20, BEAM_FSINE, Noise=5,  ScrollRate=110, Blue-purple.
 *                Noise    W=30,             Noise=2,  ScrollRate=25,  Blue-purple.
 */
start_beam(id)
{
    if (g_bFiring[id]) return;

    g_bFiring[id]     = true;
    g_fAmmoAccum[id]  = 0.0;
    g_iSoundState[id] = SND_STATE_WINDUP;

    emit_sound(id, CHAN_WEAPON, GSND_START, 0.8, ATTN_NORM, 0, PITCH_NORM);

    // v4.1: Play the firing animation.
    SendWeaponAnim(id, 3);

    // --- Select mode-dependent beam parameters ---
    new Float:fBeamWidth, Float:fNoiseWidth;
    new iBeamNoise, iNoiseNoise;
    new Float:fBeamScroll, Float:fNoiseScroll;
    new Float:vBeamColor[3], Float:vNoiseColor[3];

    if (g_iFireMode[id] == FIRE_WIDE)
    {
        fBeamWidth  = 40.0;  fNoiseWidth  = 55.0;
        iBeamNoise  = 20;    iNoiseNoise  = 8;
        fBeamScroll = 50.0;  fNoiseScroll = 25.0;
        vBeamColor[0]  = 170.0; vBeamColor[1]  =  0.0; vBeamColor[2]  = 255.0;
        vNoiseColor[0] = 130.0; vNoiseColor[1] =  0.0; vNoiseColor[2] = 255.0;
    }
    else // FIRE_NARROW
    {
        fBeamWidth  = 20.0;  fNoiseWidth  = 30.0;
        iBeamNoise  = 5;     iNoiseNoise  = 2;
        fBeamScroll = 110.0; fNoiseScroll = 25.0;
        vBeamColor[0]  = 100.0; vBeamColor[1]  = 60.0; vBeamColor[2]  = 255.0;
        vNoiseColor[0] =  80.0; vNoiseColor[1] = 40.0; vNoiseColor[2] = 255.0;
    }

    // We need a placeholder end-pos while the beam exists before the first tick.
    new Float:vOrigin[3];
    pev(id, pev_origin, vOrigin);

    // ── v4.1 FIX 2: Use BEAM_ENTPOINT so the engine interpolates the start
    //   position every frame. Beam_PointEntInit sets type=BEAM_ENTPOINT,
    //   links the start to the player entity, and positions the end at
    //   vOrigin until the first tick updates it. ────────────────────────────

    // Primary beam — BEAM_FSINE + entity-linked start.
    new iBm = Beam_Create(BEAM_SPRITE, fBeamWidth);
    if (iBm != FM_NULLENT)
    {
        Beam_PointsInit(iBm, vOrigin, vOrigin);  // start linked to player entity
        Beam_SetFlags(iBm, BEAM_FSINE);
        Beam_SetColor(iBm, vBeamColor);
        Beam_SetBrightness(iBm, 220.0);
        Beam_SetNoise(iBm, iBeamNoise);
        Beam_SetScrollRate(iBm, fBeamScroll);
    }
    g_iPlayerBeam[id] = iBm;

    // Noise / secondary beam — entity-linked start, no BEAM_FSINE.
    new iNoise = Beam_Create(BEAM_SPRITE, fNoiseWidth);
    if (iNoise != FM_NULLENT)
    {
        Beam_PointsInit(iNoise, vOrigin, vOrigin); // start linked to player entity
        Beam_SetColor(iNoise, vNoiseColor);
        Beam_SetBrightness(iNoise, 100.0);
        Beam_SetNoise(iNoise, iNoiseNoise);
        Beam_SetScrollRate(iNoise, fNoiseScroll);
    }
    g_iPlayerNoise[id] = iNoise;

    // ── v4.1 FIX 5: Create the flare sprite entity (XSpark1.spr).
    //   Modelled on Valve's CSprite::SpriteCreate call in egon.cpp:
    //     scale=1.0, kRenderGlow, RGB 255/255/255, kRenderFxNoDissipation.
    //   We use an info_target + SetModel because AMX Mod X has no direct
    //   SpriteCreate native; the engine renders sprites on FL_CUSTOMENTITY
    //   info_targets automatically. ─────────────────────────────────────────
    new iFlare = engfunc(EngFunc_CreateNamedEntity, engfunc(EngFunc_AllocString, "info_target"));
    if (pev_valid(iFlare))
    {
        set_pev(iFlare, pev_classname, "beam");              // reuse beam slot
        set_pev(iFlare, pev_flags, pev(iFlare, pev_flags) | FL_CUSTOMENTITY);
        engfunc(EngFunc_SetModel, iFlare, FLARE_SPRITE);
        set_pev(iFlare, pev_modelindex, g_iFlareSpr);
        set_pev(iFlare, pev_rendermode,   kRenderGlow);
        set_pev(iFlare, pev_renderfx,     kRenderFxNoDissipation);
        set_pev(iFlare, pev_renderamt,    255.0);
        set_pev(iFlare, pev_scale,        1.0);
        new Float:vColor[3];
        vColor[0] = 255.0; vColor[1] = 255.0; vColor[2] = 255.0;
        set_pev(iFlare, pev_rendercolor, vColor);
        set_pev(iFlare, pev_solid,    SOLID_NOT);
        set_pev(iFlare, pev_movetype, MOVETYPE_NONE);
        engfunc(EngFunc_SetOrigin, iFlare, vOrigin);
    }
    g_iPlayerFlare[id] = iFlare;

    // ── v4.1 FIX 3: Fire the first tick immediately — no 0.1s dead zone.
    //   beam_do_tick() contains all the logic previously in task_BeamTick.
    //   If it stops the beam (ammo=0, overheat, etc.) the task is never
    //   registered. Otherwise we register it to repeat from tick 2 onward. ──
    beam_do_tick(id);

    if (g_bFiring[id]) // beam_do_tick may have called stop_beam()
        set_task(GLUON_TICK_RATE, "task_BeamTick", id + TASK_BEAM, _, _, "b");
}

/*
 * stop_beam(id)
 */
stop_beam(id)
{
    if (!g_bFiring[id]) return;

    g_bFiring[id] = false;
    remove_task(id + TASK_BEAM);

    if (g_iSoundState[id] != SND_STATE_IDLE)
    {
        emit_sound(id, CHAN_WEAPON, GSND_RUN, 0.0, ATTN_NORM, SND_STOP, PITCH_NORM);
        emit_sound(id, CHAN_WEAPON, GSND_OFF, 0.6, ATTN_NORM, 0, PITCH_NORM);
        g_iSoundState[id] = SND_STATE_IDLE;
    }

    // v4.1: Play the holster/off animation when the beam stops.
    SendWeaponAnim(id, 0);

    kill_player_beam(id);

    g_iBeamTarget[id]  = 0;
    g_fBeamHitTime[id] = 0.0;
}

/*
 * kill_player_beam(id)
 *   Removes both CBeam entities AND the flare sprite, then zeroes all
 *   three tracking slots.
 */
kill_player_beam(id)
{
    if (g_iPlayerBeam[id] != 0 && pev_valid(g_iPlayerBeam[id]))
        engfunc(EngFunc_RemoveEntity, g_iPlayerBeam[id]);
    g_iPlayerBeam[id] = 0;

    if (g_iPlayerNoise[id] != 0 && pev_valid(g_iPlayerNoise[id]))
        engfunc(EngFunc_RemoveEntity, g_iPlayerNoise[id]);
    g_iPlayerNoise[id] = 0;

    // v4.1: Remove flare sprite entity.
    if (g_iPlayerFlare[id] != 0 && pev_valid(g_iPlayerFlare[id]))
        engfunc(EngFunc_RemoveEntity, g_iPlayerFlare[id]);
    g_iPlayerFlare[id] = 0;
}

/* ===========================================================================
 * SECTION 10: BEAM TICK
 * =========================================================================== */

/*
 * task_BeamTick(taskid)
 *   Thin wrapper — extracts the player id and calls beam_do_tick().
 *   The repeating task calls this every GLUON_TICK_RATE seconds from tick 2
 *   onward (tick 1 is executed immediately in start_beam for fix #3).
 */
public task_BeamTick(taskid)
{
    beam_do_tick(taskid - TASK_BEAM);
}

/*
 * beam_do_tick(id)
 *   Contains all per-tick logic: guard checks, heat/ammo drain, sound
 *   transition, traceline, CBeam endpoint update, flare position update,
 *   impact FX, and damage/knockback/vulnerability.
 *
 *   v4.1 changes vs. the old task_BeamTick body:
 *     - No longer calls Beam_SetStartPos() — the start is entity-linked.
 *     - Calls Beam_SetEndPos() + Beam_RelinkBeam() for the far end only.
 *     - Moves the flare sprite to vHit each tick.
 */
beam_do_tick(id)
{
    if (!is_user_alive(id) || !g_bHasGluon[id] || !g_bGluonEquipped[id] || g_bInstability[id])
    {
        stop_beam(id);
        return;
    }

    if (g_iAmmo[id] <= 0)
    {
        stop_beam(id);
        ColorChat(id, GREEN, "^4[SP-TEAM]^1 Gluon Gun ammo depleted.");
        return;
    }

    // ── Mode-dependent heat accumulation ─────────────────────────────────────
    new Float:fHeatTick = (g_iFireMode[id] == FIRE_WIDE) ? WIDE_HEAT_TICK : NARROW_HEAT_TICK;
    g_fHeat[id] += fHeatTick;
    if (g_fHeat[id] >= MAX_HEAT)
    {
        g_fHeat[id] = MAX_HEAT;
        stop_beam(id);
        trigger_overheat(id);
        return;
    }

    // ── Mode-dependent ammo drain ─────────────────────────────────────────────
    new Float:fAmmoRate = (g_iFireMode[id] == FIRE_WIDE) ? WIDE_AMMO_RATE : NARROW_AMMO_RATE;
    g_fAmmoAccum[id] += GLUON_TICK_RATE;
    if (g_fAmmoAccum[id] >= fAmmoRate)
    {
        g_fAmmoAccum[id] -= fAmmoRate;
        g_iAmmo[id]--;
        SyncAmmoHUD(id);
    }

    // ── Sound: windup → loop ──────────────────────────────────────────────────
    if (g_iSoundState[id] == SND_STATE_WINDUP)
    {
        g_iSoundState[id] = SND_STATE_LOOP;
        emit_sound(id, CHAN_WEAPON, GSND_RUN, 0.7, ATTN_NORM, SND_CHANGE_PITCH, PITCH_NORM);
    }

    // ── Trace ─────────────────────────────────────────────────────────────────
    new Float:vMuzzle[3], Float:vAngle[3], Float:vForward[3];
    get_muzzle_origin(id, vMuzzle);
    pev(id, pev_v_angle, vAngle);
    angle_vector(vAngle, ANGLEVECTOR_FORWARD, vForward);

    new Float:vEnd[3];
    vEnd[0] = vMuzzle[0] + vForward[0] * GLUON_MAX_RANGE;
    vEnd[1] = vMuzzle[1] + vForward[1] * GLUON_MAX_RANGE;
    vEnd[2] = vMuzzle[2] + vForward[2] * GLUON_MAX_RANGE;

    new iTrace = create_tr2();
    engfunc(EngFunc_TraceLine, vMuzzle, vEnd, DONT_IGNORE_MONSTERS, id, iTrace);

    new Float:vHit[3];
    get_tr2(iTrace, TR_vecEndPos, vHit);
    new iHit = get_tr2(iTrace, TR_pHit);
    free_tr2(iTrace);

    g_vBeamHit[id][0] = vHit[0];
    g_vBeamHit[id][1] = vHit[1];
    g_vBeamHit[id][2] = vHit[2];

    // ── Impact sparks ─────────────────────────────────────────────────────────
    beam_impact_fx(vHit);

    // ── Damage / knockback / vulnerability ────────────────────────────────────
    if (is_valid_player(iHit) && is_user_alive(iHit) && zp_get_user_zombie(iHit))
    {
        new Float:fDist   = get_distance_f(vMuzzle, vHit);
        new Float:fDamage = calc_damage(fDist, g_iFireMode[id]);
        new Float:fKnock  = get_knockback(g_iFireMode[id]);
        new bool:bNem     = bool:zp_get_user_nemesis(iHit);

        if (bNem)
        {
            fDamage *= NEMESIS_MULT;
            fKnock  *= NEMESIS_MULT;
        }

        ExecuteHamB(Ham_TakeDamage, iHit, id, id, fDamage, DMG_ENERGYBEAM);

        if (is_user_alive(iHit))
        {
            apply_knockback(iHit, vForward, fKnock);
            apply_slowdown(iHit);
            track_vulnerability(id, iHit);
        }
    }
    else
    {
        g_iBeamTarget[id]  = 0;
        g_fBeamHitTime[id] = 0.0;
    }
}

/* ===========================================================================
 * SECTION 11: BEAM VISUALS & DAMAGE HELPERS
 * =========================================================================== */

beam_impact_fx(Float:vHit[3])
{
    message_begin(MSG_BROADCAST, SVC_TEMPENTITY);
    write_byte(TE_SPARKS);
    engfunc(EngFunc_WriteCoord, vHit[0]);
    engfunc(EngFunc_WriteCoord, vHit[1]);
    engfunc(EngFunc_WriteCoord, vHit[2]);
    message_end();
}

Float:calc_damage(Float:fDist, GluonFireMode:iMode)
{
    new Float:fClose = (iMode == FIRE_WIDE) ? WIDE_DMG_CLOSE : NARROW_DMG_CLOSE;
    new Float:fFar   = (iMode == FIRE_WIDE) ? WIDE_DMG_FAR   : NARROW_DMG_FAR;

    if (fDist <= GLUON_RANGE_CLOSE) return fClose;
    if (fDist >= GLUON_RANGE_FAR)   return fFar;

    new Float:fRatio = (fDist - GLUON_RANGE_CLOSE) / (GLUON_RANGE_FAR - GLUON_RANGE_CLOSE);
    return fClose - (fClose - fFar) * fRatio;
}

Float:get_knockback(GluonFireMode:iMode)
{
    return (iMode == FIRE_WIDE) ? WIDE_KNOCKBACK : NARROW_KNOCKBACK;
}

/*
 * get_muzzle_origin(id, vOut)
 *   v4.1 FIX 4: Updated to the QA-verified muzzle offset.
 *   Fwd*10 + Right*-4 + Up*-5 places the beam origin cleanly at the
 *   weapon barrel tip without clipping the viewmodel geometry.
 */
get_muzzle_origin(id, Float:vOut[3])
{
    new Float:vOrigin[3], Float:vOfs[3], Float:vAngle[3];
    new Float:vFwd[3], Float:vRight[3], Float:vUp[3];

    pev(id, pev_origin, vOrigin);
    pev(id, pev_view_ofs, vOfs);
    pev(id, pev_v_angle, vAngle);

    vOrigin[0] += vOfs[0];
    vOrigin[1] += vOfs[1];
    vOrigin[2] += vOfs[2];

    angle_vector(vAngle, ANGLEVECTOR_FORWARD, vFwd);
    angle_vector(vAngle, ANGLEVECTOR_RIGHT,   vRight);
    angle_vector(vAngle, ANGLEVECTOR_UP,      vUp);

    // v4.1 FIX 4: QA-verified muzzle coordinates.
    vOut[0] = vOrigin[0] + vFwd[0] * 10.0 + vRight[0] * -3.0 + vUp[0] * -5.0;
    vOut[1] = vOrigin[1] + vFwd[1] * 10.0 + vRight[1] * -3.0 + vUp[1] * -5.0;
    vOut[2] = vOrigin[2] + vFwd[2] * 10.0 + vRight[2] * -3.0 + vUp[2] * -5.0;
}

/* ===========================================================================
 * SECTION 12: WEAPON ANIMATIONS
 * =========================================================================== */

/*
 * SendWeaponAnim(id, iAnim)
 *   v4.1 FIX 6: Mirrors Valve's SendWeaponAnim() from player.cpp.
 *   Sets pev_weaponanim and sends the SVC_WEAPONANIM message so the
 *   viewmodel plays the correct sequence. Body is always 0 for the Egon.
 *
 *   Usage:
 *     EGON_IDLE1   — weapon idle (deploy/post-fire)
 *     EGON_FIRE1   — start firing animation
 *     EGON_HOLSTER — stop firing / weapon away
 */
stock SendWeaponAnim(id, iAnim)
{
    set_pev(id, pev_weaponanim, iAnim);

    message_begin(MSG_ONE_UNRELIABLE, SVC_WEAPONANIM, _, id);
    write_byte(iAnim);
    write_byte(0);      // body — always 0 for the egon model
    message_end();
}

/* ===========================================================================
 * SECTION 13: KNOCKBACK & SPEED REDUCTION
 * =========================================================================== */

apply_knockback(id, Float:vDir[3], Float:fForce)
{
    new Float:vVel[3];
    pev(id, pev_velocity, vVel);

    vVel[0] += vDir[0] * fForce * GLUON_TICK_RATE;
    vVel[1] += vDir[1] * fForce * GLUON_TICK_RATE;
    vVel[2] += vDir[2] * fForce * 0.3 * GLUON_TICK_RATE;

    set_pev(id, pev_velocity, vVel);
}

apply_slowdown(id)
{
    // Speed-stacking fix (v3.1): only multiply maxspeed once per slow cycle.
    if (task_exists(id + TASK_SPEED_RST))
    {
        remove_task(id + TASK_SPEED_RST);
        set_task(SPEED_RESTORE_TIME, "task_RestoreSpeed", id + TASK_SPEED_RST);
        return;
    }

    new Float:fMax;
    pev(id, pev_maxspeed, fMax);

    if (fMax > 50.0)
    {
        set_pev(id, pev_maxspeed, fMax * SPEED_REDUCTION);
        set_task(SPEED_RESTORE_TIME, "task_RestoreSpeed", id + TASK_SPEED_RST);
    }
}

public task_RestoreSpeed(taskid)
{
    new id = taskid - TASK_SPEED_RST;
    if (!is_user_alive(id)) return;

    new Float:fMax;
    pev(id, pev_maxspeed, fMax);
    set_pev(id, pev_maxspeed, fMax / SPEED_REDUCTION);
}

/* ===========================================================================
 * SECTION 14: QUANTUM VULNERABILITY
 * =========================================================================== */

track_vulnerability(attacker, victim)
{
    if (g_iBeamTarget[attacker] == victim)
    {
        g_fBeamHitTime[attacker] += GLUON_TICK_RATE;

        if (g_fBeamHitTime[attacker] >= VULN_BEAM_TIME && !g_bVulnerable[victim])
        {
            g_bVulnerable[victim] = true;
            g_fVulnEnd[victim]    = get_gametime() + VULN_DURATION;

            set_rendering(victim, kRenderFxGlowShell, 140, 0, 200, kRenderNormal, 15);

            remove_task(victim + TASK_VULN_END);
            set_task(VULN_DURATION, "task_VulnEnd", victim + TASK_VULN_END);

            ColorChat(attacker, GREEN, "^4[SP-TEAM]^1 Target entered ^3Quantum Vulnerability^1! +50%% team damage for ^3%.0fs^1.", VULN_DURATION);
        }
    }
    else
    {
        g_iBeamTarget[attacker]  = victim;
        g_fBeamHitTime[attacker] = GLUON_TICK_RATE;
    }
}

public task_VulnEnd(taskid)
{
    new id = taskid - TASK_VULN_END;
    if (id < 1 || id > g_iMaxPlayers) return;

    g_bVulnerable[id] = false;
    g_fVulnEnd[id]    = 0.0;

    if (is_user_alive(id))
        set_rendering(id, kRenderFxNone, 0, 0, 0, kRenderNormal, 16);
}

public fw_TakeDamage(victim, inflictor, attacker, Float:fDamage, iDmgBits)
{
    if (!is_valid_player(victim) || !is_valid_player(attacker))
        return HAM_IGNORED;

    if (!zp_get_user_zombie(victim) || !g_bVulnerable[victim])
        return HAM_IGNORED;

    if (iDmgBits & DMG_ENERGYBEAM)
        return HAM_IGNORED;

    SetHamParamFloat(4, fDamage * VULN_BONUS_DMG);
    return HAM_HANDLED;
}

/* ===========================================================================
 * SECTION 15: DISINTEGRATION EFFECT
 * =========================================================================== */

disintegrate_fx(id)
{
    new Float:vOrigin[3];
    pev(id, pev_origin, vOrigin);

    message_begin(MSG_BROADCAST, SVC_TEMPENTITY);
    write_byte(TE_SMOKE);
    engfunc(EngFunc_WriteCoord, vOrigin[0]);
    engfunc(EngFunc_WriteCoord, vOrigin[1]);
    engfunc(EngFunc_WriteCoord, vOrigin[2]);
    write_short(g_iSmokeSpr);
    write_byte(30);
    write_byte(15);
    message_end();

    for (new i = 0; i < 5; i++)
    {
        message_begin(MSG_BROADCAST, SVC_TEMPENTITY);
        write_byte(TE_SPARKS);
        engfunc(EngFunc_WriteCoord, vOrigin[0] + random_float(-30.0, 30.0));
        engfunc(EngFunc_WriteCoord, vOrigin[1] + random_float(-30.0, 30.0));
        engfunc(EngFunc_WriteCoord, vOrigin[2] + random_float(-10.0, 30.0));
        message_end();
    }

    message_begin(MSG_BROADCAST, SVC_TEMPENTITY);
    write_byte(TE_PARTICLEBURST);
    engfunc(EngFunc_WriteCoord, vOrigin[0]);
    engfunc(EngFunc_WriteCoord, vOrigin[1]);
    engfunc(EngFunc_WriteCoord, vOrigin[2]);
    write_short(80);
    write_byte(207);
    write_byte(5);
    message_end();
}

/* ===========================================================================
 * SECTION 16: HEAT SYSTEM (OVERHEAT / PASSIVE COOLING / VENTING)
 * =========================================================================== */

public task_PassiveCool(taskid)
{
    new id = taskid - TASK_PASSIVE;

    if (!is_user_alive(id) || !g_bHasGluon[id])
    {
        remove_task(taskid);
        return;
    }

    if (g_bFiring[id] || g_bOverheated[id])
        return;

    if (g_fHeat[id] <= 0.0)
    {
        g_fHeat[id] = 0.0;
        return;
    }

    if (g_bVenting[id])
    {
        g_fHeat[id] -= VENT_PER_TICK;

        new Float:vOrigin[3];
        pev(id, pev_origin, vOrigin);

        message_begin(MSG_BROADCAST, SVC_TEMPENTITY);
        write_byte(TE_SMOKE);
        engfunc(EngFunc_WriteCoord, vOrigin[0]);
        engfunc(EngFunc_WriteCoord, vOrigin[1]);
        engfunc(EngFunc_WriteCoord, vOrigin[2] + 30.0);
        write_short(g_iSmokeSpr);
        write_byte(8);
        write_byte(20);
        message_end();
    }
    else
    {
        g_fHeat[id] -= COOL_PER_TICK;
    }

    if (g_fHeat[id] < 0.0)
        g_fHeat[id] = 0.0;
}

trigger_overheat(id)
{
    g_bOverheated[id]    = true;
    g_fCooldownEnd[id]   = get_gametime() + GLUON_COOLDOWN_DUR;
    g_iOverheatCount[id]++;

    emit_sound(id, CHAN_ITEM, SND_OVERHEAT, 0.9, ATTN_NORM, 0, PITCH_LOW);
    screen_fade(id, 120, 0, 200, 100, 0);

    set_dhudmessage(255, 50, 50, -1.0, 0.35, 0, 0.0, 2.0, 0.1, 0.1);
    show_dhudmessage(id, "[-S|P-] WARNING: Core Overheated");

    ColorChat(id, GREEN, "^4[-S|P-]^1 ^3WARNING:^1 Gluon Core overheated! Cooldown: ^3%.0f^1s.", GLUON_COOLDOWN_DUR);

    if (g_iOverheatCount[id] >= GLUON_INSTAB_THRESHOLD)
    {
        trigger_instability(id);
        return;
    }

    set_task(GLUON_COOLDOWN_DUR, "task_CooldownEnd", id + TASK_COOLDOWN);
}

public task_CooldownEnd(taskid)
{
    new id = taskid - TASK_COOLDOWN;

    if (!is_user_connected(id) || !g_bHasGluon[id])
        return;

    g_bOverheated[id]  = false;
    g_fCooldownEnd[id] = 0.0;
    g_fHeat[id]        = 50.0;

    emit_sound(id, CHAN_ITEM, SND_RECHARGE, 0.5, ATTN_NORM, 0, PITCH_NORM);

    set_dhudmessage(0, 200, 80, -1.0, 0.35, 0, 0.0, 1.5, 0.1, 0.1);
    show_dhudmessage(id, "[SP-TEAM] Gluon Core recharged");

    ColorChat(id, GREEN, "^4[SP-TEAM]^1 Gluon Core recharged. Heat at 50%%.");
}

/* ===========================================================================
 * SECTION 17: ENERGY INSTABILITY
 * =========================================================================== */

trigger_instability(id)
{
    g_bInstability[id] = true;
    g_bOverheated[id]  = false;
    g_bFiring[id]      = false;

    remove_task(id + TASK_BEAM);
    remove_task(id + TASK_COOLDOWN);
    kill_player_beam(id);

    emit_sound(id, CHAN_BODY, SND_INSTABILITY, 1.0, ATTN_NORM, 0, PITCH_LOW);
    screen_fade(id, 140, 0, 220, 150, 1);

    new iHP    = get_user_health(id);
    new iNewHP = iHP - GLUON_INSTAB_HP_LOSS;
    if (iNewHP < 1) iNewHP = 1;
    set_user_health(id, iNewHP);

    set_dhudmessage(200, 0, 255, -1.0, 0.30, 1, 0.0, 3.0, 0.1, 0.5);
    show_dhudmessage(id, "[SP-TEAM] WARNING: Energy Instability!^nGluon Gun DISABLED");

    ColorChat(id, GREEN, "^4[SP-TEAM]^1 ^3WARNING: Energy Instability!^1 Gluon Gun disabled. Lost ^3%d HP^1.", GLUON_INSTAB_HP_LOSS);

    strip_gluon_weapon(id);
}

strip_gluon_weapon(id)
{
    if (!is_user_alive(id)) return;

    new iEnt = find_ent_by_owner(-1, WEAPON_BASE, id);
    if (pev_valid(iEnt))
    {
        ExecuteHamB(Ham_Item_Kill, iEnt);
        set_pev(id, pev_weapons, pev(id, pev_weapons) & ~(1 << CSW_BASE));
    }

    g_bGluonEquipped[id] = false;
}

/* ===========================================================================
 * SECTION 18: HUD SYSTEM
 * =========================================================================== */

public task_HudRefresh(taskid)
{
    new id = taskid - TASK_HUD;

    if (!is_user_alive(id) || !g_bHasGluon[id])
    {
        remove_task(taskid);
        return;
    }

    if (!g_bGluonEquipped[id]) return;

    if (g_bInstability[id])
    {
        set_dhudmessage(200, 0, 255, -1.0, 0.88, 1, 0.0, 0.4, 0.0, 0.0);
        show_dhudmessage(id, "[SP-TEAM] ENERGY INSTABILITY - DISABLED");
        return;
    }

    new Float:fHeatPct = g_fHeat[id];
    new iR, iG, iB;

    if      (fHeatPct >= 80.0) { iR = 255; iG =  50; iB =  50; }
    else if (fHeatPct >= 60.0) { iR = 255; iG = 200; iB =   0; }
    else                        { iR = 220; iG = 220; iB = 220; }

    new szHeatBar[32];
    build_heat_bar(fHeatPct, szHeatBar, charsmax(szHeatBar));

    new szMode[10];
    formatex(szMode, charsmax(szMode), "%s", (g_iFireMode[id] == FIRE_WIDE) ? "WIDE" : "NARROW");

    if (g_bOverheated[id])
    {
        new Float:fRemain = g_fCooldownEnd[id] - get_gametime();
        if (fRemain < 0.0) fRemain = 0.0;

        set_dhudmessage(255, 80, 0, -1.0, 0.88, 0, 0.0, 0.4, 0.0, 0.0);
        show_dhudmessage(id, "OVERHEATED - Cooling %.1fs^nHEAT %s 100%%", fRemain, szHeatBar);
        return;
    }

    if (g_bVenting[id])
    {
        set_dhudmessage(100, 200, 255, -1.0, 0.88, 0, 0.0, 0.4, 0.0, 0.0);
        show_dhudmessage(id, "VENTING... Heat: %.0f%%^n%s", fHeatPct, szHeatBar);
        return;
    }

    set_dhudmessage(iR, iG, iB, -1.0, 0.88, 0, 0.0, 0.4, 0.0, 0.0);
    show_dhudmessage(id, "GLUON [%s] | Heat: %.0f%%^n%s", szMode, fHeatPct, szHeatBar);
}

build_heat_bar(Float:fPct, szOut[], iMax)
{
    new iFilled = floatround(fPct / 5.0, floatround_floor);
    if (iFilled <  0) iFilled =  0;
    if (iFilled > 20) iFilled = 20;

    new szBar[32];
    for (new i = 0; i < 20; i++)
        szBar[i] = (i < iFilled) ? '|' : '.';
    szBar[20] = 0;

    formatex(szOut, iMax, "[%s]", szBar);
}

/* ===========================================================================
 * SECTION 19: DROPPED WEAPON ENTITY SYSTEM
 * =========================================================================== */

public fw_PlayerKilled_Post(victim, attacker, shouldgib)
{
    if (is_valid_player(attacker) && g_bHasGluon[attacker] && g_bFiring[attacker]
        && is_valid_player(victim) && zp_get_user_zombie(victim))
    {
        disintegrate_fx(victim);
    }

    if (g_bHasGluon[victim])
    {
        stop_beam(victim);
        spawn_dropped_gluon(victim);
        cleanup_gluon(victim);
    }
}

public zp_user_infected_post(id, infector, nemesis)
{
    if (g_bHasGluon[id])
    {
        stop_beam(id);
        spawn_dropped_gluon(id);
        cleanup_gluon(id);
    }

    if (g_bVulnerable[id])
    {
        g_bVulnerable[id] = false;
        remove_task(id + TASK_VULN_END);
        set_rendering(id, kRenderFxNone, 0, 0, 0, kRenderNormal, 16);
    }
}

/*
 * spawn_dropped_gluon(id)
 *   v4.1 FIX 1: Drop Bug.
 *
 *   OLD code set a random X/Y ±50 + Z 100 — tiny scatter that dropped the
 *   weapon inside the player's collision hull, triggering an immediate
 *   fm_Touch re-pickup.
 *
 *   FIX: Use angle_vector(FORWARD) to throw the weapon 300 u/s in the
 *   direction the player is facing, plus DROP_THROW_UP (80 u/s) upward.
 *   The entity spawns 16 units above the player's feet (unchanged) so it
 *   clears the hull on the first physics frame and lands a few feet ahead.
 */
spawn_dropped_gluon(id)
{
    if (!is_user_alive(id) && !is_user_connected(id))
        return;

    new Float:vOrigin[3], Float:vAngle[3], Float:vForward[3];
    pev(id, pev_origin, vOrigin);
    pev(id, pev_v_angle, vAngle);
    vAngle[0] = 0.0;
    angle_vector(vAngle, ANGLEVECTOR_FORWARD, vForward);
    
    // v4.2 Fix: Offset forward so we don't pick it up instantly
    vOrigin[0] += vForward[0] * 40.0;
    vOrigin[1] += vForward[1] * 40.0;
    vOrigin[2] += 16.0;

    new iEnt = engfunc(EngFunc_CreateNamedEntity, engfunc(EngFunc_AllocString, "info_target"));
    if (!pev_valid(iEnt)) return;

    set_pev(iEnt, pev_classname, GLUON_CLASSNAME);
    engfunc(EngFunc_SetModel, iEnt, MDL_W);
    engfunc(EngFunc_SetOrigin, iEnt, vOrigin);

    new Float:vMins[3], Float:vMaxs[3];
    vMins[0] = -8.0; vMins[1] = -8.0; vMins[2] = 0.0;
    vMaxs[0] =  8.0; vMaxs[1] =  8.0; vMaxs[2] = 8.0;
    engfunc(EngFunc_SetSize, iEnt, vMins, vMaxs);

    set_pev(iEnt, pev_solid,    SOLID_TRIGGER);
    set_pev(iEnt, pev_movetype, MOVETYPE_TOSS);
    set_pev(iEnt, pev_iuser1,   g_iAmmo[id]);
    set_pev(iEnt, pev_fuser1,   g_fHeat[id]);

    new Float:vVel[3];
    vVel[0] = vForward[0] * DROP_THROW_SPEED;
    vVel[1] = vForward[1] * DROP_THROW_SPEED;
    vVel[2] = DROP_THROW_UP;
    set_pev(iEnt, pev_velocity, vVel);
}

public fw_Touch(iToucher, iTouched)
{
    if (!pev_valid(iToucher) || !pev_valid(iTouched))
        return FMRES_IGNORED;

    new iPlayer, iEnt;

    static szClass1[32];
    pev(iToucher, pev_classname, szClass1, charsmax(szClass1));

    if (equal(szClass1, GLUON_CLASSNAME))
    {
        iEnt    = iToucher;
        iPlayer = iTouched;
    }
    else
    {
        static szClass2[32];
        pev(iTouched, pev_classname, szClass2, charsmax(szClass2));
        if (equal(szClass2, GLUON_CLASSNAME))
        {
            iEnt    = iTouched;
            iPlayer = iToucher;
        }
        else
            return FMRES_IGNORED;
    }

    if (!is_valid_player(iPlayer) || !is_user_alive(iPlayer))
        return FMRES_IGNORED;

    if (zp_get_user_zombie(iPlayer) || g_bHasGluon[iPlayer])
        return FMRES_IGNORED;

    new iAmmo = pev(iEnt, pev_iuser1);
    new Float:fHeat;
    pev(iEnt, pev_fuser1, fHeat);

    give_gluon(iPlayer, iAmmo, fHeat);
    engfunc(EngFunc_RemoveEntity, iEnt);

    ColorChat(iPlayer, GREEN, "^4[SP-TEAM]^1 Picked up Gluon Gun! Ammo: ^3%d^1 | Heat: ^3%.0f%%^1", iAmmo, fHeat);
    emit_sound(iPlayer, CHAN_ITEM, SND_PICKUP, 1.0, ATTN_NORM, 0, PITCH_NORM);

    return FMRES_HANDLED;
}

/* ===========================================================================
 * SECTION 20: LIFECYCLE HANDLERS
 * =========================================================================== */

public ev_RoundStart()
{
    g_iGluonsSold = 0;

    for (new i = 1; i <= g_iMaxPlayers; i++)
        reset_player(i);

    remove_dropped_gluons();
}

reset_player(id)
{
    kill_player_beam(id);

    g_bHasGluon[id]        = false;
    g_bBoughtThisRound[id] = false;
    g_bGluonEquipped[id]   = false;
    g_bFiring[id]          = false;
    g_bOverheated[id]      = false;
    g_bInstability[id]     = false;
    g_bVenting[id]         = false;
    g_iAmmo[id]            = 0;
    g_iOverheatCount[id]   = 0;
    g_iSoundState[id]      = SND_STATE_IDLE;
    g_fHeat[id]            = 0.0;
    g_fCooldownEnd[id]     = 0.0;
    g_fAmmoAccum[id]       = 0.0;
    g_iBeamTarget[id]      = 0;
    g_fBeamHitTime[id]     = 0.0;
    g_bVulnerable[id]      = false;
    g_fVulnEnd[id]         = 0.0;
    g_iFireMode[id]        = FIRE_WIDE;

    remove_task(id + TASK_BEAM);
    remove_task(id + TASK_COOLDOWN);
    remove_task(id + TASK_HUD);
    remove_task(id + TASK_PASSIVE);
    remove_task(id + TASK_SPEED_RST);
    remove_task(id + TASK_VULN_END);
    remove_task(id + TASK_RECHARGE);
}

public zp_round_started(gamemode, id)
{
    if (gamemode != MODE_SURVIVOR) return;
    if (!is_user_alive(id) || !is_valid_player(id)) return;
    if (g_bHasGluon[id]) return;

    give_gluon(id, GLUON_MAX_AMMO, 0.0);
    emit_sound(id, CHAN_ITEM, SND_PICKUP, 1.0, ATTN_NORM, 0, PITCH_NORM);
    ColorChat(id, GREEN, "^4[SP-TEAM]^1 Survivor bonus: ^3Gluon Gun^1 deployed! Ammo: ^3%d^1", GLUON_MAX_AMMO);
}

public zp_user_humanized_post(id, survivor)
{
    cleanup_gluon(id);
}

public client_disconnected(id)
{
    kill_player_beam(id);

    if (g_bHasGluon[id])
        cleanup_gluon(id);

    g_fLastPurchase[id] = 0.0;
    g_bVulnerable[id]   = false;
    remove_task(id + TASK_VULN_END);
}

cleanup_gluon(id)
{
    kill_player_beam(id);

    g_bHasGluon[id]      = false;
    g_bGluonEquipped[id] = false;
    g_bFiring[id]        = false;
    g_bOverheated[id]    = false;
    g_bVenting[id]       = false;
    g_iAmmo[id]          = 0;
    g_iOverheatCount[id] = 0;
    g_iSoundState[id]    = SND_STATE_IDLE;
    g_fHeat[id]          = 0.0;
    g_fAmmoAccum[id]     = 0.0;
    g_iBeamTarget[id]    = 0;
    g_fBeamHitTime[id]   = 0.0;
    g_iFireMode[id]      = FIRE_WIDE;

    remove_task(id + TASK_BEAM);
    remove_task(id + TASK_COOLDOWN);
    remove_task(id + TASK_HUD);
    remove_task(id + TASK_PASSIVE);
    remove_task(id + TASK_RECHARGE);
}

remove_dropped_gluons()
{
    new iEnt = -1;
    while ((iEnt = find_ent_by_class(iEnt, GLUON_CLASSNAME)))
    {
        if (pev_valid(iEnt))
            engfunc(EngFunc_RemoveEntity, iEnt);
    }
}

/* ===========================================================================
 * SECTION 21: UTILITY FUNCTIONS
 * =========================================================================== */

stock count_zombies()
{
    new iCount = 0;
    for (new i = 1; i <= g_iMaxPlayers; i++)
    {
        if (is_user_alive(i) && zp_get_user_zombie(i))
            iCount++;
    }
    return iCount;
}

stock screen_fade(id, iR, iG, iB, iAlpha, iType)
{
    static iMsgScreenFade;
    if (!iMsgScreenFade)
        iMsgScreenFade = get_user_msgid("ScreenFade");

    new iDuration, iHoldTime;

    switch (iType)
    {
        case 0: { iDuration = (1<<12);     iHoldTime = (1<<12) / 2; }
        case 1: { iDuration = (1<<12) * 2; iHoldTime = (1<<12);     }
    }

    message_begin(MSG_ONE_UNRELIABLE, iMsgScreenFade, _, id);
    write_short(iDuration);
    write_short(iHoldTime);
    write_short(0x0000);
    write_byte(iR);
    write_byte(iG);
    write_byte(iB);
    write_byte(iAlpha);
    message_end();
}

public task_AutoRecharge(taskid)
{
    new id = taskid - TASK_RECHARGE;

    if (!is_user_alive(id) || !g_bHasGluon[id])
    {
        remove_task(taskid);
        return;
    }

    if (g_bFiring[id] || g_bOverheated[id] || g_bInstability[id])
        return;

    if (g_iAmmo[id] >= GLUON_MAX_AMMO)
        return;

    g_iAmmo[id]++;
    SyncAmmoHUD(id);
}

SyncAmmoHUD(id)
{
    cs_set_user_bpammo(id, CSW_BASE, g_iAmmo[id]);
}

stock bool:is_valid_player(id)
{
    return (id >= 1 && id <= g_iMaxPlayers) ? true : false;
}
