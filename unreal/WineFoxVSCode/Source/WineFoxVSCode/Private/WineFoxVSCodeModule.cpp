// Tools > Open in VS Code (Linux), for Unreal Editor running in Wine. In a Blueprint editor it
// opens the Blueprint's C++ parent class (.h and .cpp); anywhere else the project's Linux
// workspace (<Project>.linux.code-workspace from Wine Fox, else <Project>.code-workspace, else
// the project folder). VS Code is started on the Linux side through Wine's __wine_unix_spawnvp:
// WINEFOX_CODE (Wine Fox sets it when it starts the editor), else code or codium from PATH.

#include "Modules/ModuleManager.h"
#include "ToolMenus.h"
#include "SourceCodeNavigation.h"
#include "Toolkits/AssetEditorToolkitMenuContext.h"
#include "Engine/Blueprint.h"
#include "Misc/Paths.h"
#include "HAL/FileManager.h"
#include "Framework/Notifications/NotificationManager.h"
#include "Widgets/Notifications/SNotificationList.h"

#include "Windows/AllowWindowsPlatformTypes.h"
#include <windows.h>
#include "Windows/HideWindowsPlatformTypes.h"

#define LOCTEXT_NAMESPACE "WineFoxVSCode"

DEFINE_LOG_CATEGORY_STATIC(LogWineFoxVSCode, Log, All);

namespace
{
	typedef char* (__cdecl* FUnixFileName)(const WCHAR* Dos);
	typedef LONG (WINAPI* FUnixSpawn)(char* const Argv[], int Wait);

	template <typename T>
	T Wine(const wchar_t* Module, const char* Name)
	{
		return reinterpret_cast<T>(reinterpret_cast<void*>(GetProcAddress(GetModuleHandleW(Module), Name)));
	}

	// The Windows path as the Linux one; empty when Wine does not know it
	FString ToUnix(const FString& Path)
	{
		static FUnixFileName UnixFileName = Wine<FUnixFileName>(L"kernel32.dll", "wine_get_unix_file_name");
		FString Full = FPaths::ConvertRelativePathToFull(Path);
		FPaths::MakePlatformFilename(Full);
		char* Unix = UnixFileName ? UnixFileName(*Full) : nullptr;
		if (!Unix)
		{
			return FString();
		}
		FString Result = UTF8_TO_TCHAR(Unix);
		HeapFree(GetProcessHeap(), 0, Unix);
		return Result;
	}

	void Tell(const FText& Text)
	{
		FNotificationInfo Info(Text);
		Info.ExpireDuration = 6.0f;
		FSlateNotificationManager::Get().AddNotification(Info);
	}

	// VS Code with these files, through a shell on the Linux side that starts it in the
	// background: 0 when it started, 127 when there is no VS Code
	void OpenInCode(const TArray<FString>& Paths)
	{
		static FUnixSpawn Spawn = Wine<FUnixSpawn>(L"ntdll.dll", "__wine_unix_spawnvp");
		if (!Spawn)
		{
			Tell(LOCTEXT("NotWine", "Open in VS Code (Linux) works only when the editor runs in Wine."));
			return;
		}
		static const char* Script =
			"c=${WINEFOX_CODE:-$(command -v code || command -v codium)}; [ -n \"$c\" ] || exit 127; "
			"$c \"$@\" >/dev/null 2>&1 & exit 0";
		TArray<FString> Words = { TEXT("/usr/bin/env"), TEXT("-u"), TEXT("LD_LIBRARY_PATH"), TEXT("-u"), TEXT("LD_PRELOAD"),
		                          TEXT("/bin/sh"), TEXT("-c"), UTF8_TO_TCHAR(Script), TEXT("winefox-code") };
		for (const FString& Path : Paths)
		{
			FString Unix = ToUnix(Path);
			if (!Unix.IsEmpty())
			{
				Words.Add(Unix);
			}
		}

		TArray<TArray<char>> Utf8;
		for (const FString& Word : Words)
		{
			FTCHARToUTF8 Converted(*Word);
			TArray<char>& Bytes = Utf8.AddDefaulted_GetRef();
			Bytes.Append(Converted.Get(), Converted.Length());
			Bytes.Add('\0');
		}
		TArray<char*> Argv;
		for (TArray<char>& Bytes : Utf8)
		{
			Argv.Add(Bytes.GetData());
		}
		Argv.Add(nullptr);

		const LONG Status = Spawn(Argv.GetData(), 1);
		UE_LOG(LogWineFoxVSCode, Log, TEXT("code %s: %d"), *FString::Join(Paths, TEXT(" ")), (int32)Status);
		if (Status == 127)
		{
			Tell(LOCTEXT("NoCode", "VS Code was not found on the Linux side (code or codium in PATH, or WINEFOX_CODE)."));
		}
		else if (Status != 0)
		{
			Tell(FText::Format(LOCTEXT("Failed", "VS Code could not be started ({0})."), FText::AsNumber((int32)Status)));
		}
	}

	FString ProjectWorkspace()
	{
		const FString Folder = FPaths::ConvertRelativePathToFull(FPaths::ProjectDir());
		for (const TCHAR* Pattern : { TEXT("*.linux.code-workspace"), TEXT("*.code-workspace") })
		{
			TArray<FString> Found;
			IFileManager::Get().FindFiles(Found, *FPaths::Combine(Folder, Pattern), true, false);
			if (Found.Num())
			{
				return FPaths::Combine(Folder, Found[0]);
			}
		}
		return Folder;
	}

	// The Blueprint being edited here, if this is a Blueprint editor
	UBlueprint* EditedBlueprint(const FToolMenuContext& Context)
	{
		if (const UAssetEditorToolkitMenuContext* Editor = Context.FindContext<UAssetEditorToolkitMenuContext>())
		{
			for (UObject* Object : Editor->GetEditingObjects())
			{
				if (UBlueprint* Blueprint = Cast<UBlueprint>(Object))
				{
					return Blueprint;
				}
			}
		}
		return nullptr;
	}

	void Open(const FToolMenuContext& Context)
	{
		TArray<FString> Paths = { ProjectWorkspace() };
		if (const UBlueprint* Blueprint = EditedBlueprint(Context))
		{
			const UClass* Class = Blueprint->ParentClass;
			while (Class && !Class->HasAnyClassFlags(CLASS_Native))
			{
				Class = Class->GetSuperClass();
			}
			FString Header, Source;
			if (Class && FSourceCodeNavigation::FindClassHeaderPath(Class, Header))
			{
				Paths.Add(Header);
				if (FSourceCodeNavigation::FindClassSourcePath(Class, Source))
				{
					Paths.Add(Source);
				}
			}
			else if (Class)
			{
				Tell(FText::Format(LOCTEXT("NoSource", "No source files found for {0}: opening the project."),
				                   FText::FromString(Class->GetName())));
			}
		}
		OpenInCode(Paths);
	}
}

class FWineFoxVSCodeModule : public IModuleInterface
{
public:
	virtual void StartupModule() override
	{
		UToolMenus::RegisterStartupCallback(FSimpleMulticastDelegate::FDelegate::CreateRaw(this, &FWineFoxVSCodeModule::AddMenu));
	}

	virtual void ShutdownModule() override
	{
		UToolMenus::UnRegisterStartupCallback(this);
		UToolMenus::UnregisterOwner(this);
	}

private:
	void AddMenu()
	{
		FToolMenuOwnerScoped Owner(this);
		// every editor's Tools menu: the level editor's and the asset editors'
		UToolMenu* Menu = UToolMenus::Get()->ExtendMenu("MainFrame.MainMenu.Tools");
		FToolMenuSection& Section = Menu->FindOrAddSection("Programming");
		Section.AddMenuEntry("WineFoxOpenInCode",
			LOCTEXT("Label", "Open in VS Code (Linux)"),
			LOCTEXT("Tooltip", "In a Blueprint editor: its C++ parent class. Elsewhere: the project's Linux workspace."),
			FSlateIcon(),
			FToolUIActionChoice(FToolUIAction(FToolMenuExecuteAction::CreateStatic(&Open))));
	}
};

IMPLEMENT_MODULE(FWineFoxVSCodeModule, WineFoxVSCode)

#undef LOCTEXT_NAMESPACE
