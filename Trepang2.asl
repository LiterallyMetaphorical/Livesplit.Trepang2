state("CPPFPS-Win64-Shipping") { }

startup
{
	Assembly.Load(File.ReadAllBytes("Components/asl-help")).CreateInstance("Basic");
	vars.Helper.GameName = "Trepang2";
	vars.Helper.Settings.CreateFromXml("Components/Trepang2.Settings.xml");
	vars.Helper.AlertLoadless();

    // these are the fname structs that we do not want to update if their current value is None
    vars.FNamesNoNone = new List<string>() { "missionFName" };
    // mission names to start timer on when entering from the safehouse
    vars.Missions = new List<string>() { "Mission_Prologue_C", "Mission_Mothman_C", "Mission_Cultists_C", "Mission_Ghosts_C", "Mission_HorizonHQ_C" };
}

init
{
    // basic ASL setup
    vars.CompletedSplits = new Dictionary<string, bool>();
    // this function is a helper for checking splits that may or may not exist in settings,
    // and if we want to do them only once
    vars.CheckSplit = (Func<string, bool>)(key => {
        // if the split doesn't exist, or it's off, or we've done it already
        if (!settings.ContainsKey(key)
          || !settings[key]
          || vars.CompletedSplits.ContainsKey(key) && vars.CompletedSplits[key]
        ) {
            return false;
        }

        vars.CompletedSplits[key] = true;
        vars.Log("Completed: " + key);
        return true;
    });

    #region UE introspection and property setup
    vars.GWorld = vars.Helper.ScanRel(8, "0F 2E ?? 74 ?? 48 8B 1D ?? ?? ?? ?? 48 85 DB 74");
    vars.Log("Found GWorld at 0x" + vars.GWorld.ToString("X"));
    vars.GEngine = vars.Helper.ScanRel(7, "A8 01 75 ?? 48 C7 05") + 0x4;
    vars.Log("Found GEngine at 0x" + vars.GEngine.ToString("X"));
    var FNamePool = vars.Helper.ScanRel(13, "89 5C 24 ?? 89 44 24 ?? 74 ?? 48 8D 15");
    vars.Log("Found FNamePool at 0x" + FNamePool.ToString("X"));

    // The following code derefences FName structs to their string counterparts by
    // indexing the FNamePool table

    // `fname` is the actual struct, not a pointer to the struct
    vars.CachedFNames = new Dictionary<long, string>();
    vars.ReadFName = (Func<long, string>)(fname => 
    {
        if (vars.CachedFNames.ContainsKey(fname)) return vars.CachedFNames[fname];

        int name_offset  = (int) fname & 0xFFFF;
        int chunk_offset = (int) (fname >> 0x10) & 0xFFFF;

        var base_ptr = new DeepPointer((IntPtr) FNamePool + chunk_offset * 0x8 + 0x10, name_offset * 0x2);
        byte[] name_metadata = base_ptr.DerefBytes(game, 2);

        // First 10 bits are the size, but we read the bytes out of order
        // e.g. 3C05 in memory is 0011 1100 0000 0101, but really the bytes we want are the last 8 and the first two, in that order.
        int size = name_metadata[1] << 2 | (name_metadata[0] & 0xC0) >> 6;

        // read the next (size) bytes after the name_metadata
        IntPtr name_addr;
        base_ptr.DerefOffsets(game, out name_addr);
        // 2 bytes here for the name_metadata
        string name = game.ReadString(name_addr + 0x2, size);

        vars.CachedFNames[fname] = name;
        return name;
    });

    // allow us to cancel operations if the game closes or livesplit shutdowns
    vars.cts = new CancellationTokenSource();
    System.Threading.Tasks.Task.Run((Func<System.Threading.Tasks.Task<object>>)(async () => {
        // Unfortunately, Trepang2 has multiple versions that are simultaneously actively used for runs
        // Between these versions, the offsets for various properties change
        // So even if we have a signature for GWorld and NamePoolData, the offsets will change, breaking this
        // between versions.
        // So we need to do some UE introspection to find the actual offsets in memory (the same way our dumper would)

        #region UE internal offsets
        var UOBJECT_CLASS = 0x10;

        var UCLASS_PROPERTYLINK = 0x50;

        var UPROPERTY_NAME = 0x28;
        var UPROPERTY_OFFSET = 0x4C;
        var UPROPERTY_PROPERTYLINKNEXT = 0x58;

        var UARRAYPROPERTY_INNER = 0x78;
        var UOBJECTPROPERTY_CLASS = 0x78;
        #endregion

        #region helper definitions
        // get the UClass for a UObject instance
        Func<IntPtr, IntPtr> getObjectClass = (uobject =>
        {
            return vars.Helper.Read<IntPtr>(uobject + UOBJECT_CLASS);
        });

        // we want to, given a UClass, find the offset for `property` on that object
        // TODO: would be nice if we didn't have to traverse this multiple times if we wanted mutliple properties on the same class
        Func<IntPtr, string, IntPtr> getProperty = ((uclass, propertyName) =>
        {
            IntPtr uproperty = vars.Helper.Read<IntPtr>(uclass + UCLASS_PROPERTYLINK);

            while(uproperty != IntPtr.Zero)
            {
                var propName = vars.ReadFName(vars.Helper.Read<long>(uproperty + UPROPERTY_NAME));
                // vars.Log("  at " + propName);

                if (propName == propertyName)
                {
                    return uproperty;
                }

                uproperty = vars.Helper.Read<IntPtr>(uproperty + UPROPERTY_PROPERTYLINKNEXT);
            }

            throw new Exception("Couldn't find property " + propertyName + " in class 0x" + uclass.ToString("X"));
        });

        Func<IntPtr, IntPtr> getObjectPropertyClass = (uproperty =>
        {
            return vars.Helper.Read<IntPtr>(uproperty + UOBJECTPROPERTY_CLASS);
        });

        Func<IntPtr, IntPtr> getArrayPropertyInner = (uproperty =>
        {
            return getObjectPropertyClass(vars.Helper.Read<IntPtr>(uproperty + UARRAYPROPERTY_INNER));
        });

        Func<IntPtr, int> getPropertyOffset = (uproperty =>
        {
            return vars.Helper.Read<int>(uproperty + UPROPERTY_OFFSET);
        });
        
        // Thanks apple! This is taken directly, though the rest of this code is heavily inspired
        // https://github.com/apple1417/Autosplitters/blob/69ad5a5959527a25880fd528e43d3342b1375dda/borderlands3.asl#L572C1-L590C19
        Func<DeepPointer, System.Threading.Tasks.Task<IntPtr>> waitForPointer = (async (deepPtr) =>
        {
            IntPtr dest;
            while (true) {
                // Avoid a weird ToC/ToU that no one else seems to run into
                try {
                    if (deepPtr.DerefOffsets(game, out dest)) {
                        return game.ReadPointer(dest);
                    }
                } catch (ArgumentException) { continue; }

                await System.Threading.Tasks.Task.Delay(
                    500, vars.cts.Token
                ).ConfigureAwait(true);
                vars.cts.Token.ThrowIfCancellationRequested();
            }
        });
        #endregion
        
        #region reading properties and offsets
        IntPtr GameEngine = getObjectClass(vars.Helper.Read<IntPtr>(vars.GEngine));
        vars.Log("GameEngine at: " + GameEngine.ToString("X"));
        var GameEngine_GameInstance = getProperty(GameEngine, "GameInstance");
        var GameEngine_GameInstance_Offset = getPropertyOffset(GameEngine_GameInstance);
        vars.Log("GameInstance Offset: " + GameEngine_GameInstance_Offset.ToString("X"));

        var GameInstance_LocalPlayers = getProperty(getObjectPropertyClass(GameEngine_GameInstance), "LocalPlayers");
        var GameInstance_LocalPlayers_Offset = getPropertyOffset(GameInstance_LocalPlayers);
        vars.Log("LocalPlayers Offset: " + GameInstance_LocalPlayers_Offset.ToString("X"));

        var LocalPlayer_PlayerController = getProperty(getArrayPropertyInner(GameInstance_LocalPlayers), "PlayerController");
        var LocalPlayer_PlayerController_Offset = getPropertyOffset(LocalPlayer_PlayerController);
        vars.Log("PlayerController Offset: " + LocalPlayer_PlayerController_Offset.ToString("X"));
        
        // the PlayerController here will always actually be a PlayerControllerBP_C, but the UProperty here only knows
        // it's at least a PlayerController
        // so we unfortunately have to wait until an instance is put here, and then we can get the class off that and continue
        // reading
        var playerController = await waitForPointer(new DeepPointer(
            vars.GEngine,
            GameEngine_GameInstance_Offset,
            GameInstance_LocalPlayers_Offset,
            0x0,
            LocalPlayer_PlayerController_Offset
        ));

        vars.Log("found PlayerController: " + playerController.ToString("X"));
        var PlayerControllerBP_C = getObjectClass(playerController);
        var PlayerControllerBP_C_MyPlayer = getProperty(PlayerControllerBP_C, "MyPlayer");
        vars.Log("MyPlayer Offset: " + getPropertyOffset(PlayerController_MyPlayer).ToString("X"));

        var PlayerBP_C_bIsWearingGasMask = getProperty(getObjectPropertyClass(PlayerControllerBP_C_MyPlayer), "bIsWearingGasMask");
        vars.Log("bIsWearingGasMask Offset: " + getPropertyOffset(PlayerBP_C_bIsWearingGasMask).ToString("X"));

        var PlayerBP_C_IsUnlockingRestraints = getProperty(getObjectPropertyClass(PlayerControllerBP_C_MyPlayer), "IsUnlockingRestraints");
        vars.Log("IsUnlockingRestraints Offset: " + getPropertyOffset(PlayerBP_C_IsUnlockingRestraints).ToString("X"));
        #endregion

        return;
    }), vars.cts.Token);
    #endregion
}

update
{
    // we automatically deref this to their name without FName in update {}
    // e.g. we can access current.mission directly
    // World -> AuthorityGameMode -> CurrentCutscene -> Outer -> Name
    current.cutsceneFName = vars.Helper.Read<long>(vars.GWorld, 0x118, 0x628, 0x20, 0x18);
    // World -> GameInstance -> CurrentMissionInfoObject -> Name
    current.missionFName = vars.Helper.Read<long>(vars.GWorld, 0x180, 0x218, 0x18);
    
    // Other fun things
    // World -> GameInstance -> LocalPlayers.Data -> LocalPlayers[0] -> PlayerController -> MyPlayer -> bIsWearingGasMask
    current.IsWearingGasMask = vars.Helper.Read<bool>(vars.GWorld, 0x180, 0x38, 0x0, 0x30, 0x598, 0x1178);
    // World -> GameInstance -> LocalPlayers.Data -> LocalPlayers[0] -> PlayerController -> MyPlayer -> IsUnlockingRestraints
    current.IsUnlockingRestraints = vars.Helper.Read<bool>(vars.GWorld, 0x180, 0x38, 0x0, 0x30, 0x598, 0x2828);

    // World -> GameInstance -> CurrentLoadingWidget
    // pointer to the LoadingWidget - if we are in a loading screen, then this is set
    // so, we just check if it is set
    current.LoadingWidget = vars.Helper.Read<long>(vars.GWorld, 0x180, 0x290);

    // This is useful for more than just the isLoading {} block
    current.isLoading = current.LoadingWidget != 0 || current.missionFName == 0;

    if (!((IDictionary<string, object>)(old)).ContainsKey("cutsceneFName"))
    {
        vars.Log("Loaded values:");
        vars.Log("  cutsceneFName: " + current.cutsceneFName.ToString("X"));
        vars.Log("  missionFName: " + current.missionFName.ToString("X"));
        vars.Log("  IsUnlockingRestraints: " + current.IsUnlockingRestraints);
        vars.Log("  IsWearingGasMask: " + current.IsWearingGasMask);
        vars.Log("  LoadingWidget: " + current.LoadingWidget.ToString("X"));
        vars.Log("  isLoading: " + current.isLoading);
        return;
    }

    if (old.isLoading != current.isLoading)
    {
        vars.Log("isLoading: " + old.isLoading + " -> " + current.isLoading);
    }

    // Deref useful FNames here
    IDictionary<string, object> currdict = current;
    foreach (var fname in new List<string>(currdict.Keys))
    {
        if (!fname.EndsWith("FName"))
            continue;
        
        var key = fname.Substring(0, fname.Length-5);
        // We get nicer splits if we split on loading screens for mission changes
        if (key == "mission" && currdict.ContainsKey(key) && !current.isLoading)
            continue;

        var val = vars.ReadFName((long)currdict[fname]);
        // e.g. missionFName -> mission
        if (val == "None" && vars.FNamesNoNone.Contains(fname) && currdict.ContainsKey(key))
            continue;

        // Debugging and such
        if (!currdict.ContainsKey(key))
        {
            vars.Log(key + ": " + val);
        }
        else if (currdict[key] != val)
        {
            vars.Log(key + ": " + currdict[key] + " -> " + val);
        }

        currdict[key] = val;
    }
}

onStart
{
    // This makes sure the timer always starts at 0.00
    timer.IsGameTimePaused = true;
    
    // refresh all splits when we start the game, none are yet completed
    vars.CompletedSplits = new Dictionary<string, bool>();
}

start
{
    if (!((IDictionary<string, object>)(old)).ContainsKey("mission"))
        return false;

    if (settings["start_on_mission"]
     && old.isLoading
     && !current.isLoading
     && vars.Missions.Contains(current.mission)
    ) {
        return true;
    }

    return old.cutscene == "None" && current.cutscene == "Prologue_Intro_SequencePrologue_Intro_Master";
}

isLoading
{
    return current.isLoading;
}

split
{
    if (!((IDictionary<string, object>)(old)).ContainsKey("mission"))
        return false;

    if (!old.IsUnlockingRestraints &&
        current.IsUnlockingRestraints &&
        vars.CheckSplit("Mission_Prologue_C__restraints")
    ) {
        return true;
    }

    if (old.IsWearingGasMask &&
        !current.IsWearingGasMask &&
        current.mission == "Mission_Ghosts_C" &&
        !current.isLoading &&
        vars.CheckSplit("Mission_Ghosts_C__gasmask")
    ) {
        return true;
    }

    if (old.mission != current.mission)
    {
        if (old.mission == "Mission_Safehouse_C")
        {
            return vars.CheckSplit(current.mission + "__enter");
        }
     
        if (current.mission == "Mission_Safehouse_C"
        || (current.mission == "Mission_FrontEnd_C" && old.mission == "Mission_SyndicateHQFinal_C")
        ) {
            return vars.CheckSplit(old.mission + "__exit");
        }
    }

    if (old.cutscene == "None" && old.cutscene != current.cutscene)
    {
        return vars.CheckSplit(current.cutscene);
    }

}

exit
{
    vars.cts.Cancel();
    timer.IsGameTimePaused = true;
}

shutdown
{
    vars.cts.Cancel();
}