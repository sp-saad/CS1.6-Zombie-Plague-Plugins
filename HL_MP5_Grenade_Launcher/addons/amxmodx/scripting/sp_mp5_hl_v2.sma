/*
    [ZP] Extra MP5 with Grenade Launcher - Half-Life Inspired
    Version 1.0
    
    Description:
    - Extra Item purchasable by Humans only (once per round)
    - Primary fire: Normal MP5 bullets
    - Secondary fire: Grenade launcher (3 grenades max, no refill)
    - Weapon removed and reset at round end
    
    Compatible with: AMX Mod X 1.8.0+ and Zombie Plague 4.3+
*/

#include <amxmodx>
#include <amxmisc>
#include <fakemeta>
#include <fakemeta_util>
#include <hamsandwich>
#include <xs>
#include <fun>
#include <engine>
#include <cstrike>
#include <zombieplague>

#if AMXX_VERSION_NUM < 180
    #assert AMX Mod X v1.8.0 or greater library required!
#endif

#define PLUGIN "[ZP] Extra MP5 Grenade Launcher"
#define VERSION "1.0"
#define AUTHOR "SP-TEAM (sp-saad & sp-half)"

#define RemoveEntity(%1) engfunc(EngFunc_RemoveEntity, %1)

#define GRENADE_CLASSNAME "hl_mp5_grenade"

#define CSW_MP5 CSW_MP5NAVY

new const ITEM_NAME[] = "HL MP5 Grenade Launcher"
const ITEM_COST = 20

new const V_MODEL[] = "models/sp_weapons_opposing_force/v_mp5.mdl"
new const P_MODEL[] = "models/sp_mp5/p_9mmar.mdl"
new const W_MODEL[] = "models/sp_mp5/w_9mmar.mdl"

new const GRENADE_MODEL[] = "models/grenade.mdl"

new const SOUND_GL_FIRE[] = "weapons/glauncher.wav"
new const SOUND_GL_EXPLODE[] = "weapons/explode3.wav"
new const SOUND_EMPTY[] = "weapons/dryfire1.wav"

new const SPRITE_EXPLOSION[] = "sprites/zerogxplode.spr"
new const SPRITE_SMOKE[] = "sprites/steam1.spr"

new g_sprExplosion
new g_sprSmoke

new g_cvBulletDamageMult

new g_iItemId

new g_cvEnable
new g_cvGrenadeDamage
new g_cvGrenadeRadius
new g_cvGrenadeSpeed
new g_cvGrenadeCooldown
new g_cvMaxGrenades

new g_maxPlayers

new bool:g_bHasExtraMP5[33]
new bool:g_bBoughtThisRound[33]
new g_iGrenadeCount[33]
new Float:g_fNextGrenade[33]

new g_msgScreenShake

public plugin_init()
{
    register_plugin(PLUGIN, VERSION, AUTHOR)
    
    g_iItemId = zp_register_extra_item(ITEM_NAME, ITEM_COST, ZP_TEAM_HUMAN)
    
    g_cvEnable = register_cvar("zp_mp5gl_enable", "1")
    g_cvGrenadeDamage = register_cvar("zp_mp5gl_grenade_damage", "300")
    g_cvGrenadeRadius = register_cvar("zp_mp5gl_grenade_radius", "200.0")
    g_cvGrenadeSpeed = register_cvar("zp_mp5gl_grenade_speed", "800.0")
    g_cvGrenadeCooldown = register_cvar("zp_mp5gl_cooldown", "2.0")
    g_cvMaxGrenades = register_cvar("zp_mp5gl_max_grenades", "3")
    
    register_forward(FM_CmdStart, "fw_CmdStart")
    register_forward(FM_Think, "fw_Think")
    register_forward(FM_Touch, "fw_Touch")
    
    RegisterHam(Ham_Spawn, "player", "fw_PlayerSpawn_Post", 1)
    RegisterHam(Ham_Killed, "player", "fw_PlayerKilled")
    RegisterHam(Ham_Item_Deploy, "weapon_mp5navy", "fw_MP5Deploy_Post", 1)
    
    register_event("HLTV", "event_NewRound", "a", "1=0", "2=0")
    
    register_clcmd("say /mp5", "cmd_MP5Info")
    register_clcmd("say_team /mp5", "cmd_MP5Info")
    
    g_msgScreenShake = get_user_msgid("ScreenShake")
    g_cvBulletDamageMult = register_cvar("zp_mp5gl_bullet_damage_mult", "2.5")

    RegisterHam(Ham_TakeDamage, "player", "fw_TakeDamage_Pre", 0)
    g_maxPlayers = get_maxplayers()
}

public plugin_precache()
{
    precache_model(V_MODEL)
    precache_model(P_MODEL)
    precache_model(W_MODEL)
    precache_model(GRENADE_MODEL)
    
    precache_sound(SOUND_GL_FIRE)
    precache_sound(SOUND_GL_EXPLODE)
    precache_sound(SOUND_EMPTY)
    
    g_sprExplosion = precache_model(SPRITE_EXPLOSION)
    g_sprSmoke = precache_model(SPRITE_SMOKE)
}

public client_disconnected(id)
{
    ResetPlayerData(id)
}

public event_NewRound()
{
    RemoveAllGrenades()
    
    for(new i = 1; i <= g_maxPlayers; i++)
    {
        if(is_user_connected(i))
        {
            if(g_bHasExtraMP5[i])
            {
                RemoveExtraMP5(i)
            }
            ResetPlayerData(i)
        }
    }
}

public fw_PlayerSpawn_Post(id)
{
    if(!is_user_alive(id))
        return HAM_IGNORED
    
    ResetPlayerData(id)
    
    return HAM_IGNORED
}

public fw_PlayerKilled(victim, attacker, shouldgib)
{
    if(g_bHasExtraMP5[victim])
    {
        g_bHasExtraMP5[victim] = false
    }
    return HAM_IGNORED
}

ResetPlayerData(id)
{
    g_bHasExtraMP5[id] = false
    g_bBoughtThisRound[id] = false
    g_iGrenadeCount[id] = 0
    g_fNextGrenade[id] = 0.0
}

public zp_extra_item_selected(id, itemid)
{
    if(itemid != g_iItemId)
        return
    
    if(!get_pcvar_num(g_cvEnable))
    {
        client_print(id, print_chat, "[SP-TEAM] This item is currently disabled.")
        return
    }
    
    if(g_bBoughtThisRound[id])
    {
        client_print(id, print_chat, "[SP-TEAM] You can only buy this once per round!")
        zp_set_user_ammo_packs(id, zp_get_user_ammo_packs(id) + ITEM_COST)
        return
    }
    
    if(g_bHasExtraMP5[id])
    {
        client_print(id, print_chat, "[SP-TEAM] You already have the HL MP5!")
        zp_set_user_ammo_packs(id, zp_get_user_ammo_packs(id) + ITEM_COST)
        return
    }
    
    GiveExtraMP5(id)
}

public zp_user_infected_post(id, infector)
{
    if(g_bHasExtraMP5[id])
    {
        g_bHasExtraMP5[id] = false
    }
    g_iGrenadeCount[id] = 0
}

public zp_user_humanized_post(id, survivor)
{
    ResetPlayerData(id)
}

GiveExtraMP5(id)
{
    fm_strip_user_gun(id, CSW_MP5)
    fm_give_item(id, "weapon_mp5navy")
    
    cs_set_user_bpammo(id, CSW_MP5, 120)
    
    g_bHasExtraMP5[id] = true
    g_bBoughtThisRound[id] = true
    g_iGrenadeCount[id] = get_pcvar_num(g_cvMaxGrenades)
    g_fNextGrenade[id] = 0.0
    
    client_print(id, print_chat, "[SP-TEAM] You bought the HL MP5 with Grenade Launcher!")
    client_print(id, print_chat, "[SP-TEAM] Press Mouse2 to fire grenades. Grenades: %d", g_iGrenadeCount[id])
}

RemoveExtraMP5(id)
{
    if(!is_user_alive(id))
        return
    
    g_bHasExtraMP5[id] = false
    g_iGrenadeCount[id] = 0
}

public fw_MP5Deploy_Post(ent)
{
    if(!pev_valid(ent))
        return HAM_IGNORED
    
    new owner = pev(ent, pev_owner)
    
    if(!is_user_alive(owner))
        return HAM_IGNORED
    
    if(!g_bHasExtraMP5[owner])
        return HAM_IGNORED
    
    set_pev(owner, pev_viewmodel2, V_MODEL)
    set_pev(owner, pev_weaponmodel2, P_MODEL)
    
    return HAM_IGNORED
}

public fw_TakeDamage_Pre(victim, inflictor, attacker, Float:damage, damage_type)
{
    if(!is_user_connected(attacker) || !is_user_connected(victim) || attacker == victim)
        return HAM_IGNORED
        
    if(!(damage_type & DMG_BULLET))
        return HAM_IGNORED
        
    if(g_bHasExtraMP5[attacker] && get_user_weapon(attacker) == CSW_MP5)
    {
        new Float:mult = get_pcvar_float(g_cvBulletDamageMult)
        
        SetHamParamFloat(4, damage * mult)
        
        return HAM_HANDLED
    }
    
    return HAM_IGNORED
}

public fw_CmdStart(id, ucHandle, seed)
{
    if(!is_user_alive(id))
        return FMRES_IGNORED
    
    if(zp_get_user_zombie(id))
        return FMRES_IGNORED
    
    if(!g_bHasExtraMP5[id])
        return FMRES_IGNORED
    
    new curWeapon = get_user_weapon(id)
    if(curWeapon != CSW_MP5)
        return FMRES_IGNORED
    
    new buttons = get_uc(ucHandle, UC_Buttons)
    
    if(buttons & IN_ATTACK2)
    {
        set_uc(ucHandle, UC_Buttons, buttons & ~IN_ATTACK2)
        
        FireGrenadeLauncher(id)
    }
    
    return FMRES_IGNORED
}

FireGrenadeLauncher(id)
{
    new Float:gameTime = get_gametime()
    
    if(gameTime < g_fNextGrenade[id])
    {
        return
    }
    
    if(g_iGrenadeCount[id] <= 0)
    {
        emit_sound(id, CHAN_WEAPON, SOUND_EMPTY, VOL_NORM, ATTN_NORM, 0, PITCH_NORM)
        client_print(id, print_center, "Out of grenades!")
        g_fNextGrenade[id] = gameTime + 0.5
        return
    }
    
    g_iGrenadeCount[id]--
    
    new Float:cooldown = get_pcvar_float(g_cvGrenadeCooldown)
    g_fNextGrenade[id] = gameTime + cooldown
    
    LaunchGrenade(id)
    
    emit_sound(id, CHAN_WEAPON, SOUND_GL_FIRE, VOL_NORM, ATTN_NORM, 0, PITCH_NORM)
    
    new Float:punchAngle[3]
    punchAngle[0] = random_float(-5.0, -3.0)
    punchAngle[1] = random_float(-1.0, 1.0)
    punchAngle[2] = 0.0
    set_pev(id, pev_punchangle, punchAngle)
    
    client_print(id, print_center, "Grenades: %d", g_iGrenadeCount[id])
}

LaunchGrenade(owner)
{
    new ent = engfunc(EngFunc_CreateNamedEntity, engfunc(EngFunc_AllocString, "info_target"))
    
    if(!pev_valid(ent))
        return 0
    
    set_pev(ent, pev_classname, GRENADE_CLASSNAME)
    
    engfunc(EngFunc_SetModel, ent, GRENADE_MODEL)
    
    new Float:playerOrigin[3]
    new Float:playerViewOfs[3]
    new Float:eyePosition[3]
    new Float:playerAngles[3]
    new Float:forwardVec[3]
    new Float:rightVec[3]
    new Float:upVec[3]
    
    pev(owner, pev_origin, playerOrigin)
    pev(owner, pev_view_ofs, playerViewOfs)
    xs_vec_add(playerOrigin, playerViewOfs, eyePosition)
    
    pev(owner, pev_v_angle, playerAngles)
    
    angle_vector(playerAngles, ANGLEVECTOR_FORWARD, forwardVec)
    angle_vector(playerAngles, ANGLEVECTOR_RIGHT, rightVec)
    angle_vector(playerAngles, ANGLEVECTOR_UP, upVec)
    
    new Float:spawnPos[3]
    spawnPos[0] = eyePosition[0] + forwardVec[0] * 16.0 + rightVec[0] * 4.0
    spawnPos[1] = eyePosition[1] + forwardVec[1] * 16.0 + rightVec[1] * 4.0
    spawnPos[2] = eyePosition[2] + forwardVec[2] * 16.0 - 4.0
    
    engfunc(EngFunc_SetOrigin, ent, spawnPos)
    engfunc(EngFunc_SetSize, ent, Float:{-2.0, -2.0, -2.0}, Float:{2.0, 2.0, 2.0})
    
    set_pev(ent, pev_solid, SOLID_BBOX)
    set_pev(ent, pev_movetype, MOVETYPE_TOSS)
    set_pev(ent, pev_gravity, 0.5)
    
    new Float:launchSpeed = get_pcvar_float(g_cvGrenadeSpeed)
    new Float:grenadeVel[3]
    
    xs_vec_mul_scalar(forwardVec, launchSpeed, grenadeVel)
    
    grenadeVel[2] += 50.0
    
    set_pev(ent, pev_velocity, grenadeVel)
    
    new Float:angularVel[3]
    angularVel[0] = random_float(200.0, 400.0)
    angularVel[1] = random_float(200.0, 400.0)
    angularVel[2] = 0.0
    set_pev(ent, pev_avelocity, angularVel)
    
    set_pev(ent, pev_angles, playerAngles)
    
    set_pev(ent, pev_owner, owner)
    
    set_pev(ent, pev_rendermode, kRenderNormal)
    set_pev(ent, pev_renderfx, kRenderFxNone)
    
    set_pev(ent, pev_iuser1, owner)
    set_pev(ent, pev_fuser1, get_gametime() + 3.0)
    
    set_pev(ent, pev_nextthink, get_gametime() + 0.1)
    
    return ent
}

public fw_Think(ent)
{
    if(!pev_valid(ent))
        return FMRES_IGNORED
    
    new classname[32]
    pev(ent, pev_classname, classname, charsmax(classname))
    
    if(!equal(classname, GRENADE_CLASSNAME))
        return FMRES_IGNORED
    
    new Float:explodeTime
    pev(ent, pev_fuser1, explodeTime)
    
    if(get_gametime() >= explodeTime)
    {
        GrenadeExplode(ent)
        return FMRES_SUPERCEDE
    }
    
    set_pev(ent, pev_nextthink, get_gametime() + 0.1)
    
    return FMRES_IGNORED
}

public fw_Touch(ent, touched)
{
    if(!pev_valid(ent))
        return FMRES_IGNORED
    
    new classname[32]
    pev(ent, pev_classname, classname, charsmax(classname))
    
    if(!equal(classname, GRENADE_CLASSNAME))
        return FMRES_IGNORED
    
    new owner = pev(ent, pev_iuser1)
    
    if(touched == owner)
        return FMRES_IGNORED
    
    GrenadeExplode(ent)
    return FMRES_SUPERCEDE
}

GrenadeExplode(ent)
{
    if(!pev_valid(ent))
        return
    
    new owner = pev(ent, pev_iuser1)
    
    new Float:explosionPos[3]
    pev(ent, pev_origin, explosionPos)
    
    emit_sound(ent, CHAN_BODY, SOUND_GL_EXPLODE, VOL_NORM, ATTN_NORM, 0, PITCH_NORM)
    
    message_begin(MSG_BROADCAST, SVC_TEMPENTITY)
    write_byte(TE_EXPLOSION)
    engfunc(EngFunc_WriteCoord, explosionPos[0])
    engfunc(EngFunc_WriteCoord, explosionPos[1])
    engfunc(EngFunc_WriteCoord, explosionPos[2])
    write_short(g_sprExplosion)
    write_byte(25)
    write_byte(15)
    write_byte(0)
    message_end()
    
    message_begin(MSG_BROADCAST, SVC_TEMPENTITY)
    write_byte(TE_SMOKE)
    engfunc(EngFunc_WriteCoord, explosionPos[0])
    engfunc(EngFunc_WriteCoord, explosionPos[1])
    engfunc(EngFunc_WriteCoord, explosionPos[2] + 30.0)
    write_short(g_sprSmoke)
    write_byte(30)
    write_byte(10)
    message_end()
    
    new Float:baseDamage = float(get_pcvar_num(g_cvGrenadeDamage))
    new Float:blastRadius = get_pcvar_float(g_cvGrenadeRadius)
    
    for(new i = 1; i <= g_maxPlayers; i++)
    {
        if(!is_user_alive(i))
            continue
        
        if(!zp_get_user_zombie(i))
            continue
        
        new Float:victimPos[3]
        pev(i, pev_origin, victimPos)
        
        new Float:distToVictim = get_distance_f(explosionPos, victimPos)
        
        if(distToVictim > blastRadius)
            continue
        
        if(!CanSeeTarget(explosionPos, victimPos, ent))
            continue
        
        new Float:damageMultiplier = 1.0 - (distToVictim / blastRadius)
        new Float:finalDamage = baseDamage * damageMultiplier
        
        new attacker = owner
        if(attacker <= 0 || attacker > g_maxPlayers || !is_user_connected(attacker))
        {
            attacker = i
        }
        
        ExecuteHamB(Ham_TakeDamage, i, ent, attacker, finalDamage, DMG_BLAST)
        
        ApplyKnockback(i, explosionPos, finalDamage)
        
        ScreenShake(i)
    }
    
    RemoveEntity(ent)
}

bool:CanSeeTarget(Float:startPos[3], Float:endPos[3], ignoreEnt)
{
    new tr = create_tr2()
    engfunc(EngFunc_TraceLine, startPos, endPos, IGNORE_MONSTERS, ignoreEnt, tr)
    
    new Float:frac
    get_tr2(tr, TR_flFraction, frac)
    
    free_tr2(tr)
    
    return (frac >= 1.0)
}

ApplyKnockback(id, Float:blastOrigin[3], Float:damage)
{
    new Float:victimOrigin[3]
    new Float:knockDir[3]
    new Float:currentVel[3]
    
    pev(id, pev_origin, victimOrigin)
    
    xs_vec_sub(victimOrigin, blastOrigin, knockDir)
    knockDir[2] = 0.3
    xs_vec_normalize(knockDir, knockDir)
    
    new Float:knockPower = damage * 3.0
    
    pev(id, pev_velocity, currentVel)
    
    currentVel[0] += knockDir[0] * knockPower
    currentVel[1] += knockDir[1] * knockPower
    currentVel[2] += knockDir[2] * knockPower * 0.5
    
    set_pev(id, pev_velocity, currentVel)
}

ScreenShake(id)
{
    message_begin(MSG_ONE, g_msgScreenShake, _, id)
    write_short(1<<14)
    write_short(1<<13)
    write_short(1<<14)
    message_end()
}

RemoveAllGrenades()
{
    new ent = -1
    while((ent = engfunc(EngFunc_FindEntityByString, ent, "classname", GRENADE_CLASSNAME)) != 0)
    {
        if(pev_valid(ent))
            RemoveEntity(ent)
    }
}

public cmd_MP5Info(id)
{
    if(!is_user_alive(id))
    {
        client_print(id, print_chat, "[SP-TEAM] You must be alive to use this.")
        return PLUGIN_HANDLED
    }
    
    if(g_bHasExtraMP5[id])
    {
        client_print(id, print_chat, "[SP-TEAM] Grenades remaining: %d | Press Mouse2 to fire grenade", g_iGrenadeCount[id])
    }
    else if(g_bBoughtThisRound[id])
    {
        client_print(id, print_chat, "[SP-TEAM] You already purchased this item this round.")
    }
    else
    {
        client_print(id, print_chat, "[SP-TEAM] Buy 'HL MP5 Grenade Launcher' from Extra Items menu!")
    }
    
    return PLUGIN_HANDLED
}