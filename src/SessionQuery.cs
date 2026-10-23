// Embedded into PowerShell via Add-Type. Queries Terminal Services for
// interactive sessions and whether the workstation is locked.
using System;
using System.Collections.Generic;
using System.Diagnostics.Eventing.Reader;
using System.Runtime.InteropServices;

public static class SessionQuery
{
    private const int WTSUserName = 5;
    private const int WTSDomainName = 7;
    private const int WTSSessionInfoEx = 24;
    private const int WTS_SESSIONSTATE_LOCK = 0;
    private const int WTS_SESSIONSTATE_UNLOCK = 1;
    private const uint DESKTOP_READOBJECTS = 0x0001;
    private const uint DESKTOP_WRITEOBJECTS = 0x0080;
    private const uint DESKTOP_SWITCHDESKTOP = 0x0100;

    /// <summary>
    /// WTS SessionFlags polarity. Docs: 0=Lock, 1=Unlock. Many builds reverse this.
    /// Default treats flag==1 as locked; calibrated at runtime from SecurityLog/Desktop.
    /// </summary>
    private static bool s_wtsOneMeansLocked = true;
    private static bool s_wtsPolarityCalibrated;

    /// <summary>Last non-fatal diagnostic from session/lock queries (for PowerShell debugging).</summary>
    public static string LastError { get; private set; }

    /// <summary>How the last lock decision was made (WTS / Desktop / SecurityLog / FailClosed).</summary>
    public static string LastLockSource { get; private set; }

    /// <summary>Raw WTS SessionFlags from the last ResolveLocked call (-1 if unknown).</summary>
    public static int LastWtsSessionFlags { get; private set; }

    /// <summary>True after WTS polarity was calibrated against SecurityLog or Desktop.</summary>
    public static bool WtsPolarityCalibrated
    {
        get { return s_wtsPolarityCalibrated; }
    }

    /// <summary>Current interpretation: whether WTS flag value 1 means locked.</summary>
    public static bool WtsOneMeansLocked
    {
        get { return s_wtsOneMeansLocked; }
    }

    private static void SetLastError(string message)
    {
        LastError = message ?? string.Empty;
    }

    [DllImport("wtsapi32.dll", EntryPoint = "WTSEnumerateSessionsW", SetLastError = true)]
    private static extern bool WTSEnumerateSessions(
        IntPtr hServer,
        int Reserved,
        int Version,
        out IntPtr ppSessionInfo,
        out int pCount);

    [DllImport("wtsapi32.dll", EntryPoint = "WTSQuerySessionInformationW", SetLastError = true)]
    private static extern bool WTSQuerySessionInformation(
        IntPtr hServer,
        int sessionId,
        int wtsInfoClass,
        out IntPtr ppBuffer,
        out int pBytesReturned);

    [DllImport("wtsapi32.dll")]
    private static extern void WTSFreeMemory(IntPtr pMemory);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentProcessId();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ProcessIdToSessionId(uint dwProcessId, out uint pSessionId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr OpenInputDesktop(uint dwFlags, bool fInherit, uint dwDesiredAccess);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool CloseDesktop(IntPtr hDesktop);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WTS_SESSION_INFO
    {
        public int SessionId;
        public IntPtr pWinStationName;
        public WTS_CONNECTSTATE_CLASS State;
    }

    private enum WTS_CONNECTSTATE_CLASS
    {
        WTSActive,
        WTSConnected,
        WTSConnectQuery,
        WTSShadow,
        WTSDisconnected,
        WTSIdle,
        WTSListen,
        WTSReset,
        WTSDown,
        WTSInit
    }

    public sealed class SessionStatus
    {
        public int SessionId { get; set; }
        public string UserName { get; set; }
        public string DomainName { get; set; }
        public string State { get; set; }
        public bool IsLocked { get; set; }
        public bool IsActive { get; set; }
        public string LockSource { get; set; }
        public int WtsSessionFlags { get; set; }
        public bool IsUnlockedActive
        {
            get { return IsActive && !IsLocked; }
        }
    }

    public static SessionStatus[] GetSessions()
    {
        var results = new List<SessionStatus>();
        IntPtr pSessions = IntPtr.Zero;
        int count = 0;

        try
        {
            if (!WTSEnumerateSessions(IntPtr.Zero, 0, 1, out pSessions, out count))
            {
                int err = Marshal.GetLastWin32Error();
                SetLastError("WTSEnumerateSessionsW failed; Win32Error=" + err);
                throw new System.ComponentModel.Win32Exception(
                    err,
                    "WTSEnumerateSessionsW failed while listing interactive sessions (Win32Error=" + err + ").");
            }

            SetLastError(string.Empty);

            int structSize = Marshal.SizeOf(typeof(WTS_SESSION_INFO));
            for (int i = 0; i < count; i++)
            {
                var info = (WTS_SESSION_INFO)Marshal.PtrToStructure(
                    new IntPtr(pSessions.ToInt64() + (i * structSize)),
                    typeof(WTS_SESSION_INFO));

                if (info.SessionId == 0)
                {
                    continue; // services session
                }

                string userName = QueryString(info.SessionId, WTSUserName);
                if (string.IsNullOrEmpty(userName))
                {
                    continue;
                }

                string domainName = QueryString(info.SessionId, WTSDomainName);
                int wtsFlags;
                string lockSource;
                // Use the session's WTS domain when present (NetBIOS); skip domain filter when empty.
                bool sessionDomainRequired = !string.IsNullOrWhiteSpace(domainName);
                bool isLocked = ResolveLocked(
                    info.SessionId, userName, domainName, sessionDomainRequired, out lockSource, out wtsFlags);

                bool isActive = info.State == WTS_CONNECTSTATE_CLASS.WTSActive;

                results.Add(new SessionStatus
                {
                    SessionId = info.SessionId,
                    UserName = userName,
                    DomainName = domainName ?? string.Empty,
                    State = info.State.ToString(),
                    IsLocked = isLocked,
                    IsActive = isActive,
                    LockSource = lockSource,
                    WtsSessionFlags = wtsFlags
                });
            }
        }
        finally
        {
            if (pSessions != IntPtr.Zero)
            {
                WTSFreeMemory(pSessions);
            }
        }

        return results.ToArray();
    }

    public static void ParseAccountName(string input, out string userName, out string domainName, out bool domainRequired)
    {
        userName = (input ?? string.Empty).Trim();
        domainName = string.Empty;
        domainRequired = false;

        if (userName.IndexOf('@') >= 0)
        {
            string[] upn = userName.Split(new[] { '@' }, 2);
            userName = upn[0];
            domainName = upn.Length > 1 ? upn[1] : string.Empty;
            // UPN suffix is DNS-style and often does not match Security log NetBIOS TargetDomainName.
            domainRequired = false;
            return;
        }

        int slash = userName.IndexOf('\\');
        if (slash >= 0)
        {
            domainName = userName.Substring(0, slash);
            userName = userName.Substring(slash + 1);
            domainRequired = !string.IsNullOrWhiteSpace(domainName);
        }
    }

    private static bool SessionMatchesAccount(SessionStatus session, string userName, string domainName, bool domainRequired)
    {
        if (!string.Equals(session.UserName, userName, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        if (!domainRequired || string.IsNullOrWhiteSpace(domainName))
        {
            return true;
        }

        return DomainNamesMatch(session.DomainName, domainName);
    }

    private static bool DomainNamesMatch(string left, string right)
    {
        if (string.IsNullOrWhiteSpace(left) || string.IsNullOrWhiteSpace(right))
        {
            return false;
        }

        if (string.Equals(left, right, StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        // Compare first DNS label to NetBIOS-style short name (CONTOSO vs contoso.com).
        string leftHead = left.Split('.')[0];
        string rightHead = right.Split('.')[0];
        return string.Equals(leftHead, rightHead, StringComparison.OrdinalIgnoreCase);
    }

    public static SessionStatus FindUserSession(string accountName)
    {
        if (string.IsNullOrWhiteSpace(accountName))
        {
            return null;
        }

        string userName;
        string domainName;
        bool domainRequired;
        ParseAccountName(accountName, out userName, out domainName, out domainRequired);
        if (string.IsNullOrWhiteSpace(userName))
        {
            return null;
        }

        foreach (var session in GetSessions())
        {
            if (SessionMatchesAccount(session, userName, domainName, domainRequired))
            {
                return session;
            }
        }

        return null;
    }

    public static bool IsUserUnlocked(string accountName)
    {
        if (string.IsNullOrWhiteSpace(accountName))
        {
            SetLastError("IsUserUnlocked called with empty accountName.");
            return false;
        }

        string userName;
        string domainName;
        bool domainRequired;
        ParseAccountName(accountName, out userName, out domainName, out domainRequired);
        if (string.IsNullOrWhiteSpace(userName))
        {
            SetLastError("IsUserUnlocked: could not parse user name from '" + accountName + "'.");
            return false;
        }

        SessionStatus[] sessions;
        try
        {
            sessions = GetSessions();
        }
        catch (Exception ex)
        {
            SetLastError("IsUserUnlocked GetSessions failed for account '" + accountName + "': " + ex);
            throw;
        }

        SessionStatus matched = null;
        foreach (var session in sessions)
        {
            if (!SessionMatchesAccount(session, userName, domainName, domainRequired))
            {
                continue;
            }

            matched = session;
            if (session.IsUnlockedActive)
            {
                LastLockSource = session.LockSource;
                LastWtsSessionFlags = session.WtsSessionFlags;
                return true;
            }
        }

        if (matched != null)
        {
            LastLockSource = matched.LockSource;
            LastWtsSessionFlags = matched.WtsSessionFlags;
        }

        return false;
    }

    private static string QueryString(int sessionId, int infoClass)
    {
        IntPtr buffer = IntPtr.Zero;
        int bytes = 0;
        try
        {
            if (!WTSQuerySessionInformation(IntPtr.Zero, sessionId, infoClass, out buffer, out bytes)
                || buffer == IntPtr.Zero)
            {
                int err = Marshal.GetLastWin32Error();
                SetLastError(
                    "WTSQuerySessionInformationW failed; sessionId=" + sessionId +
                    "; infoClass=" + infoClass + "; Win32Error=" + err + "; bytesReturned=" + bytes);
                return string.Empty;
            }

            return Marshal.PtrToStringUni(buffer) ?? string.Empty;
        }
        finally
        {
            if (buffer != IntPtr.Zero)
            {
                WTSFreeMemory(buffer);
            }
        }
    }

    private static bool IsCurrentSession(int sessionId)
    {
        uint current;
        if (!ProcessIdToSessionId(GetCurrentProcessId(), out current))
        {
            return false;
        }
        return current == (uint)sessionId;
    }

    /// <summary>
    /// Same-session lock probe: OpenInputDesktop fails when the workstation is locked.
    /// Does not work from Session 0 (SYSTEM service) for another user's session.
    /// </summary>
    private static bool TryGetLockedDesktop(out bool isLocked)
    {
        isLocked = false;
        uint access = DESKTOP_READOBJECTS | DESKTOP_WRITEOBJECTS | DESKTOP_SWITCHDESKTOP;
        IntPtr hDesktop = OpenInputDesktop(0, false, access);
        if (hDesktop == IntPtr.Zero)
        {
            int err = Marshal.GetLastWin32Error();
            // Access denied / failure while interactive usually means Winlogon holds input (locked).
            isLocked = true;
            SetLastError("OpenInputDesktop failed (treating as locked); Win32Error=" + err);
            return true;
        }

        CloseDesktop(hDesktop);
        isLocked = false;
        return true;
    }

    private static bool InterpretWtsFlags(int flags, out bool isLocked)
    {
        isLocked = false;
        if (flags != WTS_SESSIONSTATE_LOCK && flags != WTS_SESSIONSTATE_UNLOCK)
        {
            return false;
        }

        // When s_wtsOneMeansLocked: flag 1 => locked, flag 0 => unlocked (common inverted builds).
        // When false: flag 0 => locked, flag 1 => unlocked (MSDN).
        if (s_wtsOneMeansLocked)
        {
            isLocked = (flags == WTS_SESSIONSTATE_UNLOCK);
        }
        else
        {
            isLocked = (flags == WTS_SESSIONSTATE_LOCK);
        }
        return true;
    }

    private static void CalibrateWtsPolarity(bool authoritativeLocked, int flags, string authority)
    {
        if (flags != WTS_SESSIONSTATE_LOCK && flags != WTS_SESSIONSTATE_UNLOCK)
        {
            return;
        }

        bool currentInterp;
        if (!InterpretWtsFlags(flags, out currentInterp))
        {
            return;
        }

        if (currentInterp == authoritativeLocked)
        {
            s_wtsPolarityCalibrated = true;
            return;
        }

        s_wtsOneMeansLocked = !s_wtsOneMeansLocked;
        s_wtsPolarityCalibrated = true;
        SetLastError(
            "Calibrated WTS SessionFlags polarity from " + authority +
            "; wtsFlags=" + flags + "; authoritativeLocked=" + authoritativeLocked +
            "; wtsOneMeansLocked=" + s_wtsOneMeansLocked);
    }

    private static bool TryGetLockedWts(int sessionId, out bool isLocked, out int flags)
    {
        isLocked = false;
        flags = -1;
        IntPtr buffer = IntPtr.Zero;
        int bytes = 0;

        try
        {
            const int minBytes = 16;
            if (!WTSQuerySessionInformation(IntPtr.Zero, sessionId, WTSSessionInfoEx, out buffer, out bytes)
                || buffer == IntPtr.Zero
                || bytes < minBytes)
            {
                int err = Marshal.GetLastWin32Error();
                SetLastError(
                    "WTSSessionInfoEx query failed; sessionId=" + sessionId +
                    "; Win32Error=" + err + "; bytesReturned=" + bytes);
                return false;
            }

            flags = Marshal.ReadInt32(buffer, 12);
            return InterpretWtsFlags(flags, out isLocked);
        }
        catch (Exception ex)
        {
            SetLastError("TryGetLockedWts exception: " + ex);
            return false;
        }
        finally
        {
            if (buffer != IntPtr.Zero)
            {
                WTSFreeMemory(buffer);
            }
        }
    }

    /// <summary>
    /// Uses Security audit events 4800 (locked) / 4801 (unlocked) when available.
    /// Works from SYSTEM for other sessions if "Audit Other Logon/Logoff Events" is enabled.
    /// When domainRequired is false (SAM or UPN), domain filtering is skipped so NetBIOS vs DNS mismatch does not drop events.
    /// </summary>
    private static bool TryGetLockedSecurityLog(string userName, string domainName, bool domainRequired, out bool isLocked)
    {
        isLocked = false;
        try
        {
            string query =
                "*[System[(EventID=4800 or EventID=4801)]]";
            var elQuery = new EventLogQuery("Security", PathType.LogName, query)
            {
                ReverseDirection = true
            };

            using (var reader = new EventLogReader(elQuery))
            {
                for (int i = 0; i < 40; i++)
                {
                    EventRecord rec = reader.ReadEvent();
                    if (rec == null)
                    {
                        break;
                    }

                    using (rec)
                    {
                        string xml = rec.ToXml() ?? string.Empty;
                        string targetUser = GetXmlDataValue(xml, "TargetUserName");
                        string targetDomain = GetXmlDataValue(xml, "TargetDomainName");
                        if (string.IsNullOrEmpty(targetUser))
                        {
                            continue;
                        }

                        if (!string.Equals(targetUser, userName, StringComparison.OrdinalIgnoreCase))
                        {
                            continue;
                        }

                        if (domainRequired
                            && !string.IsNullOrWhiteSpace(domainName)
                            && !string.IsNullOrWhiteSpace(targetDomain)
                            && !string.Equals(targetDomain, ".", StringComparison.OrdinalIgnoreCase)
                            && !DomainNamesMatch(targetDomain, domainName)
                            && !string.Equals(targetDomain, Environment.MachineName, StringComparison.OrdinalIgnoreCase))
                        {
                            continue;
                        }

                        isLocked = (rec.Id == 4800);
                        return true;
                    }
                }
            }

            return false;
        }
        catch (Exception ex)
        {
            SetLastError("Security log lock probe unavailable: " + ex.Message);
            return false;
        }
    }

    private static string GetXmlDataValue(string xml, string name)
    {
        if (string.IsNullOrEmpty(xml) || string.IsNullOrEmpty(name))
        {
            return string.Empty;
        }

        string key = "Name=\"" + name + "\">";
        int i = xml.IndexOf(key, StringComparison.OrdinalIgnoreCase);
        if (i < 0)
        {
            return string.Empty;
        }

        i += key.Length;
        int j = xml.IndexOf('<', i);
        if (j <= i)
        {
            return string.Empty;
        }

        return xml.Substring(i, j - i).Trim();
    }

    private static bool ResolveLocked(
        int sessionId,
        string userName,
        string domainName,
        bool domainRequired,
        out string lockSource,
        out int wtsFlags)
    {
        wtsFlags = -1;
        bool wtsLocked = false;
        bool wtsKnown = TryGetLockedWts(sessionId, out wtsLocked, out wtsFlags);
        LastWtsSessionFlags = wtsFlags;

        bool desktopKnown = false;
        bool desktopLocked = false;
        if (IsCurrentSession(sessionId))
        {
            desktopKnown = TryGetLockedDesktop(out desktopLocked);
        }

        bool securityLocked = false;
        bool securityKnown = TryGetLockedSecurityLog(userName, domainName, domainRequired, out securityLocked);

        // Preference:
        // 1) Security audit (authoritative across sessions when enabled)
        // 2) Desktop probe for same-session callers
        // 3) WTS SessionFlags (polarity calibrated from 1/2 when available)
        // 4) Fail closed (locked)
        if (securityKnown)
        {
            if (wtsKnown)
            {
                CalibrateWtsPolarity(securityLocked, wtsFlags, "SecurityLog");
                InterpretWtsFlags(wtsFlags, out wtsLocked);
            }
            lockSource = "SecurityLog";
            LastLockSource = lockSource;
            if (string.IsNullOrEmpty(LastError) || LastError.IndexOf("Calibrated WTS", StringComparison.Ordinal) < 0)
            {
                SetLastError(string.Empty);
            }
            return securityLocked;
        }

        if (desktopKnown)
        {
            if (wtsKnown)
            {
                CalibrateWtsPolarity(desktopLocked, wtsFlags, "Desktop");
                InterpretWtsFlags(wtsFlags, out wtsLocked);
            }
            lockSource = "Desktop";
            LastLockSource = lockSource;
            if (wtsKnown && wtsLocked != desktopLocked && !s_wtsPolarityCalibrated)
            {
                SetLastError(
                    "WTS/Desktop disagree; preferring Desktop. wtsLocked=" + wtsLocked +
                    "; desktopLocked=" + desktopLocked + "; wtsFlags=" + wtsFlags);
            }
            else if (LastError == null || LastError.IndexOf("Calibrated WTS", StringComparison.Ordinal) < 0)
            {
                SetLastError(string.Empty);
            }
            return desktopLocked;
        }

        if (wtsKnown)
        {
            lockSource = "WTS";
            LastLockSource = lockSource;
            if (!s_wtsPolarityCalibrated)
            {
                SetLastError(
                    "Using WTS SessionFlags without SecurityLog/Desktop calibration; wtsFlags=" + wtsFlags +
                    "; wtsOneMeansLocked=" + s_wtsOneMeansLocked +
                    ". Verify with Test-Session.ps1 while locked from another session.");
            }
            else
            {
                SetLastError(string.Empty);
            }
            return wtsLocked;
        }

        lockSource = "FailClosed";
        LastLockSource = lockSource;
        SetLastError(
            "No reliable lock signal; fail-closed as locked. sessionId=" + sessionId +
            "; wtsFlags=" + wtsFlags);
        return true;
    }
}
