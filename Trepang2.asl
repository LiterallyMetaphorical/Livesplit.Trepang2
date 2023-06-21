/*
gameStatus - 4Bytes
2 in main menu and loading screen
1 in game
*/


state("CPPFPS-Win64-Shipping")
{
    int loadState    : "msmpeg2vdec.dll", 0x264F94; // 0 in game, 2 during cutscene, 1 on load screen
    string150 mission: 0x04F302F8, 0x8B0, 0x0;
}

startup
  {
		if (timer.CurrentTimingMethod == TimingMethod.RealTime)
// Asks user to change to game time if LiveSplit is currently set to Real Time.
    {        
        var timingMessage = MessageBox.Show (
            "This game uses Time without Loads (Game Time) as the main timing method.\n"+
            "LiveSplit is currently set to show Real Time (RTA).\n"+
            "Would you like to set the timing method to Game Time?",
            "LiveSplit | Trepang 2",
            MessageBoxButtons.YesNo,MessageBoxIcon.Question
        );

        if (timingMessage == DialogResult.Yes)
        {
            timer.CurrentTimingMethod = TimingMethod.GameTime;
        }
    }
}

onStart
{
    // This makes sure the timer always starts at 0.00
    timer.IsGameTimePaused = true;
}

start
{
    return old.mission == "/Game/Maps/Menu/FrontEndMenuMap" && current.mission == "/Game/Maps/Campaign/Prologue/Prologue_Persistent1";
}

isLoading
{
    return current.loadState == 1;
}

split
{
    return current.mission != old.mission;
}

exit
{
	timer.IsGameTimePaused = true;
}

update
{
//DEBUG CODE 
//print(current.gameStatus.ToString()); 
//print(current.pauseStatus.ToString()); 
//print("Current Mission is " + current.mission.ToString());
//print(modules.First().ModuleMemorySize.ToString());
}