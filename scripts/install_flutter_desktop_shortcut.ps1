param(
    [string]$ExePath = "",
    [string]$ShortcutPath = "",
    [string]$AppUserModelId = "TransVortex.Desktop",
    [string]$AppName = "TransVortex",
    [switch]$VerifyOnly,
    [switch]$Json
)

$ErrorActionPreference = "Stop"

function Add-ShortcutIdentityType {
    if ([System.Management.Automation.PSTypeName]'TransVortex.Tools.ShortcutIdentity'.Type) {
        return
    }

    $source = @"
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace TransVortex.Tools {
    [ComImport]
    [Guid("00021401-0000-0000-C000-000000000046")]
    internal class CShellLink {
    }

    [ComImport]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [Guid("000214F9-0000-0000-C000-000000000046")]
    internal interface IShellLinkW {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszFile, int cchMaxPath, IntPtr pfd, uint fFlags);
        void GetIDList(out IntPtr ppidl);
        void SetIDList(IntPtr pidl);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszName, int cchMaxName);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszDir, int cchMaxPath);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszArgs, int cchMaxPath);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);
        void GetHotkey(out short pwHotkey);
        void SetHotkey(short wHotkey);
        void GetShowCmd(out int piShowCmd);
        void SetShowCmd(int iShowCmd);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszIconPath, int cchIconPath, out int piIcon);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int iIcon);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string pszPathRel, uint dwReserved);
        void Resolve(IntPtr hwnd, uint fFlags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
    }

    [ComImport]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [Guid("0000010b-0000-0000-C000-000000000046")]
    internal interface IPersistFile {
        void GetClassID(out Guid pClassID);
        void IsDirty();
        void Load([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, uint dwMode);
        void Save([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, bool fRemember);
        void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string pszFileName);
        void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string ppszFileName);
    }

    [ComImport]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    internal interface IPropertyStore {
        void GetCount(out uint cProps);
        void GetAt(uint iProp, out PropertyKey pkey);
        void GetValue(ref PropertyKey key, out PropVariant pv);
        void SetValue(ref PropertyKey key, ref PropVariant pv);
        void Commit();
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    internal struct PropertyKey {
        public Guid fmtid;
        public uint pid;

        public PropertyKey(Guid fmtid, uint pid) {
            this.fmtid = fmtid;
            this.pid = pid;
        }
    }

    [StructLayout(LayoutKind.Explicit)]
    internal struct PropVariant {
        [FieldOffset(0)]
        public ushort vt;

        [FieldOffset(8)]
        public IntPtr pointerValue;

        public static PropVariant FromString(string value) {
            PropVariant variant = new PropVariant();
            variant.vt = 31; // VT_LPWSTR
            variant.pointerValue = Marshal.StringToCoTaskMemUni(value);
            return variant;
        }

        public string AsString() {
            if (vt == 0 || pointerValue == IntPtr.Zero) {
                return "";
            }
            if (vt != 31) {
                return "<vt:" + vt.ToString() + ">";
            }
            return Marshal.PtrToStringUni(pointerValue) ?? "";
        }
    }

    public static class ShortcutIdentity {
        private static readonly PropertyKey AppUserModelIdKey =
            new PropertyKey(new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), 5);

        [DllImport("Ole32.dll")]
        private static extern int PropVariantClear(ref PropVariant pvar);

        public static void Create(string shortcutPath, string exePath, string workingDirectory, string appName, string appUserModelId) {
            IShellLinkW link = (IShellLinkW)new CShellLink();
            link.SetPath(exePath);
            link.SetWorkingDirectory(workingDirectory);
            link.SetDescription(appName);
            link.SetIconLocation(exePath, 0);

            PropVariant appId = PropVariant.FromString(appUserModelId);
            try {
                IPropertyStore store = (IPropertyStore)link;
                PropertyKey key = AppUserModelIdKey;
                store.SetValue(ref key, ref appId);
                store.Commit();
            } finally {
                PropVariantClear(ref appId);
            }

            IPersistFile file = (IPersistFile)link;
            file.Save(shortcutPath, true);
        }

        public static string ReadAppUserModelId(string shortcutPath) {
            IShellLinkW link = (IShellLinkW)new CShellLink();
            IPersistFile file = (IPersistFile)link;
            file.Load(shortcutPath, 0);
            IPropertyStore store = (IPropertyStore)link;
            PropVariant value;
            PropertyKey key = AppUserModelIdKey;
            store.GetValue(ref key, out value);
            try {
                return value.AsString();
            } finally {
                PropVariantClear(ref value);
            }
        }

        public static string ReadTargetPath(string shortcutPath) {
            IShellLinkW link = (IShellLinkW)new CShellLink();
            IPersistFile file = (IPersistFile)link;
            file.Load(shortcutPath, 0);
            StringBuilder target = new StringBuilder(32767);
            link.GetPath(target, target.Capacity, IntPtr.Zero, 0);
            return target.ToString();
        }
    }
}
"@

    Add-Type -TypeDefinition $source -Language CSharp
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
if ([string]::IsNullOrWhiteSpace($ExePath)) {
    $releaseDir = Join-Path $repoRoot "desktop_flutter\build\windows\x64\runner\Release"
    $newExePath = Join-Path $releaseDir "TransVortex.exe"
    $legacyExePath = Join-Path $releaseDir "transvortex_desktop_flutter.exe"
    $ExePath = if (Test-Path -LiteralPath $newExePath) { $newExePath } else { $legacyExePath }
}
if ([string]::IsNullOrWhiteSpace($ShortcutPath)) {
    $ShortcutPath = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)) "$AppName.lnk"
}

$resolvedExe = Resolve-Path -LiteralPath $ExePath
$shortcutFullPath = [System.IO.Path]::GetFullPath($ShortcutPath)
$shortcutDirectory = [System.IO.Path]::GetDirectoryName($shortcutFullPath)
if ([string]::IsNullOrWhiteSpace($shortcutDirectory)) {
    throw "Shortcut path has no parent directory: $shortcutFullPath"
}

Add-ShortcutIdentityType

if (-not $VerifyOnly) {
    New-Item -ItemType Directory -Force -Path $shortcutDirectory | Out-Null
    [TransVortex.Tools.ShortcutIdentity]::Create(
        $shortcutFullPath,
        $resolvedExe.Path,
        [System.IO.Path]::GetDirectoryName($resolvedExe.Path),
        $AppName,
        $AppUserModelId
    )
}

$shortcutExists = Test-Path -LiteralPath $shortcutFullPath
$actualAppUserModelId = ""
$actualTargetPath = ""
if ($shortcutExists) {
    $actualAppUserModelId = [TransVortex.Tools.ShortcutIdentity]::ReadAppUserModelId($shortcutFullPath)
    $actualTargetPath = [TransVortex.Tools.ShortcutIdentity]::ReadTargetPath($shortcutFullPath)
}

$targetOk = $shortcutExists -and ([string]::Equals($actualTargetPath, $resolvedExe.Path, [System.StringComparison]::OrdinalIgnoreCase))
$appIdOk = $shortcutExists -and $actualAppUserModelId -eq $AppUserModelId
$ok = $targetOk -and $appIdOk

$report = [ordered]@{
    ok = $ok
    shortcut_exists = $shortcutExists
    shortcut_path = $shortcutFullPath
    exe_path = $resolvedExe.Path
    app_user_model_id = $AppUserModelId
    shortcut_app_user_model_id = $actualAppUserModelId
    shortcut_target_path = $actualTargetPath
    shortcut_target_ok = $targetOk
    shortcut_app_user_model_id_ok = $appIdOk
    created_or_updated = -not [bool]$VerifyOnly
}

if ($Json) {
    $report | ConvertTo-Json -Depth 5
} else {
    [pscustomobject]$report
}

if (-not $ok) {
    throw "TransVortex shortcut identity verification failed: $shortcutFullPath"
}
