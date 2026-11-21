using UnrealBuildTool;

public class WineFoxVSCode : ModuleRules
{
	public WineFoxVSCode(ReadOnlyTargetRules Target) : base(Target)
	{
		PrivateDependencyModuleNames.AddRange(new string[]
		{
			"Core", "CoreUObject", "Engine", "UnrealEd", "ToolMenus", "Slate", "SlateCore"
		});
		ShortName = "WFVSC";
	}
}
