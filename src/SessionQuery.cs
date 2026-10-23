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

    /// <summary>Last non-fatal diagnostic from session/lock queries (for PowerShell debugging).</summary>
    public static string LastError { get; private set; }

    /// <summary>How the last lock decision was made (WTS / Desktop / SecurityLog / FailClosed).</summary>
    public static string LastLockSource { get; private set; }

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
                bool isLocked = ResolveLocked(info.SessionId, userName, domainName, out lockSource, out wtsFlags);

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

        return string.Equals(session.DomainName, domainName, StringComparison.OrdinalIgnoreCase);
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

        foreach (var session in sessions)
        {
            if (SessionMatchesAccount(session, userName, domainName, domainRequired)
                && session.IsUnlockedActive)
            {
                LastLockSource = session.LockSource;
                return true;
            }
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
            // Docs: 0=Lock, 1=Unlock. Many Windows builds reverse this; treat 0 as unlocked, 1 as locked.
            bool known = flags == WTS_SESSIONSTATE_LOCK || flags == WTS_SESSIONSTATE_UNLOCK;
            isLocked = flags == WTS_SESSIONSTATE_UNLOCK;
            return known;
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
    /// </summary>
    private static bool TryGetLockedSecurityLog(string userName, string domainName, out bool isLocked)
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

                        if (!string.IsNullOrWhiteSpace(domainName)
                            && !string.IsNullOrWhiteSpace(targetDomain)
                            && !string.Equals(targetDomain, domainName, StringComparison.OrdinalIgnoreCase)
                            && !string.Equals(targetDomain, ".", StringComparison.OrdinalIgnoreCase))
                        {
                            string machine = Environment.MachineName;
                            if (!string.Equals(targetDomain, machine, StringComparison.OrdinalIgnoreCase))
                            {
                                continue;
                            }
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
        out string lockSource,
        out int wtsFlags)
    {
        wtsFlags = -1;
        bool wtsLocked = false;
        bool wtsKnown = TryGetLockedWts(sessionId, out wtsLocked, out wtsFlags);

        bool desktopKnown = false;
        bool desktopLocked = false;
        if (IsCurrentSession(sessionId))
        {
            desktopKnown = TryGetLockedDesktop(out desktopLocked);
        }

        bool securityLocked = false;
        bool securityKnown = TryGetLockedSecurityLog(userName, domainName, out securityLocked);

        // Preference:
        // 1) Security audit (authoritative across sessions when enabled)
        // 2) Desktop probe for same-session callers
        // 3) WTS SessionFlags
        // 4) Fail closed (locked)
        if (securityKnown)
        {
            lockSource = "SecurityLog";
            LastLockSource = lockSource;
            SetLastError(string.Empty);
            return securityLocked;
        }

        if (desktopKnown)
        {
            lockSource = "Desktop";
            LastLockSource = lockSource;
            // If WTS disagrees, prefer Desktop for same-session accuracy.
            if (wtsKnown && wtsLocked != desktopLocked)
            {
                SetLastError(
                    "WTS/Desktop disagree; preferring Desktop. wtsLocked=" + wtsLocked +
                    "; desktopLocked=" + desktopLocked + "; wtsFlags=" + wtsFlags);
            }
            else
            {
                SetLastError(string.Empty);
            }
            return desktopLocked;
        }

        if (wtsKnown)
        {
            lockSource = "WTS";
            LastLockSource = lockSource;
            SetLastError(string.Empty);
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
