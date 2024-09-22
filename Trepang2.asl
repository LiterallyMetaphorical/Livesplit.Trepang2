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

    // Unfortunately, Trepang2 has multiple versions that are simultaneously actively used for runs
    // Between these versions, the offsets for various properties change
    // So even if we have a signature for GWorld and NamePoolData, the offsets will change, breaking this
    // between versions.
    // So we need to do some UE introspection to find the actual offsets in memory (the same way our dumper would)

    #region UE internal offsets
    var UOBJECT_CLASS = 0x10;
    #endregion

    // get the UClass for a UObject instance
    Func<IntPtr, IntPtr> getObjectClass = (uobject =>
    {
        return vars.Helper.Read<IntPtr>(uobject, UOBJECT_CLASS);
    });

    // we want to, given a UClass, find the offset for `property` on that object

    vars.Log(getObjectClass(vars.GWorld).ToString("X"));


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
    timer.IsGameTimePaused = true;
}