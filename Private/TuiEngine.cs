using System;
using System.Text;
using System.Collections;
using System.Collections.Generic;
using System.Threading;
using System.Management.Automation;

namespace OmniAdmin {
    public class TuiEngine {
        // --- WIN32 CONSOLE API FOR SCROLLBAR STABILITY ---
        public static string GetProgressBar(int percent, int width, out string colorAnsi) {
            int filled = (int)Math.Round((percent / 100.0) * width);
            if (filled < 0) filled = 0;
            if (filled > width) filled = width;
            
            string bar = new string('█', filled) + new string('░', width - filled);
            if (percent >= 85) colorAnsi = "\x1b[31;1m"; // Bold Red
            else if (percent >= 60) colorAnsi = "\x1b[33;1m"; // Bold Yellow
            else colorAnsi = "\x1b[36;1m"; // Bold Cyan
            
            return bar;
        }

        public static string FormatBoxLine(string ansiContent, int frameWidth, string themeColor = "\x1b[90m") {
            int visibleLength = GetVisibleLength(ansiContent);
            int pad = frameWidth - 4 - visibleLength;
            if (pad < 0) pad = 0;
            return string.Format("{0}│\x1b[0m {1}{2} {0}│\x1b[0m\n", themeColor, ansiContent, new string(' ', pad));
        }

        public static int GetVisibleLength(string text) {
            if (string.IsNullOrEmpty(text)) return 0;
            return System.Text.RegularExpressions.Regex.Replace(text, @"\x1b\[[0-9;]*m", "").Length;
        }

        // --- DYNAMIC PROPERTY READERS (Supports Hashtable, PSObject, Reflection) ---
        public static object GetProperty(object obj, string name) {
            if (obj == null) return null;
            IDictionary dict = obj as IDictionary;
            if (dict != null) {
                if (dict.Contains(name)) return dict[name];
                return null;
            }
            if (obj.GetType().FullName == "System.Management.Automation.PSObject") {
                try {
                    var props = obj.GetType().GetProperty("Properties").GetValue(obj, null) as IEnumerable;
                    foreach (var prop in props) {
                        var pName = prop.GetType().GetProperty("Name").GetValue(prop, null) as string;
                        if (pName == name) {
                            return prop.GetType().GetProperty("Value").GetValue(prop, null);
                        }
                    }
                } catch {}
            }
            try {
                var prop = obj.GetType().GetProperty(name);
                if (prop != null) return prop.GetValue(obj, null);
                var field = obj.GetType().GetField(name);
                if (field != null) return field.GetValue(obj);
            } catch {}
            return null;
        }

        public static string GetString(object val) {
            return val != null ? val.ToString() : "";
        }

        public static string GetServiceHostString(object servicesObj) {
            if (servicesObj == null) return "";
            servicesObj = Unwrap(servicesObj);
            if (servicesObj is string) return (string)servicesObj;
            if (servicesObj is IEnumerable) {
                var list = new List<string>();
                foreach (var s in (IEnumerable)servicesObj) {
                    if (s != null) list.Add(Unwrap(s).ToString());
                }
                return string.Join(", ", list);
            }
            return servicesObj.ToString();
        }

        public static string GetString(object obj, string name) {
            var val = GetProperty(obj, name);
            return val != null ? val.ToString() : "";
        }

        public static double GetDouble(object obj, string name) {
            var val = GetProperty(obj, name);
            if (val == null) return 0;
            val = Unwrap(val);
            try { return Convert.ToDouble(val); } catch { return 0; }
        }

        public static int GetInt(object obj, string name) {
            var val = GetProperty(obj, name);
            if (val == null) return 0;
            val = Unwrap(val);
            try { return Convert.ToInt32(val); } catch { return 0; }
        }

        // Peel off PSObject wrapper so Convert.To* receives the actual CLR value.
        // Values from remote Invoke-Command are deserialized as PSObject<bool>, PSObject<double> etc.
        // and throw IConvertible exceptions when passed directly to Convert.ToBoolean / ToDouble / ToInt32.
        public static object Unwrap(object val) {
            if (val == null) return null;
            if (val.GetType().FullName == "System.Management.Automation.PSObject") {
                try {
                    var bo = val.GetType().GetProperty("BaseObject").GetValue(val, null);
                    if (bo != null && !(bo is PSObject)) return bo;
                } catch {}
            }
            return val;
        }

        public static bool ToBool(object val) {
            if (val == null) return false;
            val = Unwrap(val);
            try { return Convert.ToBoolean(val); } catch { return false; }
        }

        public static double ToNum(object val, double fallback = 0.0) {
            if (val == null) return fallback;
            val = Unwrap(val);
            try { return Convert.ToDouble(val); } catch { return fallback; }
        }

        public static int ToInt(object val, int fallback = 0) {
            if (val == null) return fallback;
            val = Unwrap(val);
            try { return Convert.ToInt32(val); } catch { return fallback; }
        }

        public static List<object> GetSortedList(IEnumerable list, string propName, bool desc) {
            var sorted = new List<object>();
            if (list == null) return sorted;
            foreach (var item in list) sorted.Add(item);
            
            sorted.Sort((a, b) => {
                var valA = GetProperty(a, propName);
                var valB = GetProperty(b, propName);
                if (valA == null && valB == null) return 0;
                if (valA == null) return desc ? 1 : -1;
                if (valB == null) return desc ? -1 : 1;
                
                int cmp = 0;
                IComparable compA = valA as IComparable;
                if (compA != null) {
                    try {
                        var typedB = Convert.ChangeType(valB, valA.GetType());
                        cmp = compA.CompareTo(typedB);
                    } catch {
                        cmp = string.Compare(valA.ToString(), valB.ToString(), StringComparison.OrdinalIgnoreCase);
                    }
                } else {
                    cmp = string.Compare(valA.ToString(), valB.ToString(), StringComparison.OrdinalIgnoreCase);
                }
                return desc ? -cmp : cmp;
            });
            return sorted;
        }

        // --- MAIN TUI LOOP ENGINE ---
        public static void Run(
            Hashtable syncHash,
            string computerName,
            int defaultPageSize,
            bool useFixedPageSize,
            bool diagnostics,
            object credential,
            string stWorkerScript,
            string initNetEngineScript
        ) {
            bool isLocal = (computerName == "localhost" || computerName == "." || string.Equals(computerName, Environment.MachineName, StringComparison.OrdinalIgnoreCase));
            
            // UI state variables
            string activeMode = "Processes"; // Processes, Services, Tasks, Apps, Users, SpeedTest
            int selectedRow = 0;
            int pageIndex = 0;
            int selColIndex = 2; // CPU column for Processes
            bool isDesc = true;
            bool paused = false;
            string filterText = "";
            bool showMainMenu = false;
            int menuSelectedIndex = 0;
            bool showServiceProps = false;
            bool showTaskProps = false;
            bool showHistoryDetail = false;
            List<object> frozenProcessList = null;
            int speedTestRowIndex = 0;
            
            // Runspaces references
            PowerShell speedTestPS = null;
            IAsyncResult speedTestAsyncHandle = null;
            PowerShell historyPS = null;
            IAsyncResult historyAsyncHandle = null;
            bool loadingHistory = false;
            List<object> historyList = null;
            int historyDays = 1;          // number of days to fetch
            bool historyConfigured = false; // true once user has chosen timeframe and started fetch

            Console.CursorVisible = false;
            Console.Write("\x1b[?1049h\x1b[H"); // Enable Alternate Screen Buffer (prevents scrollback buffer memory bloat)
            Console.Clear();

            int lastWidth = Console.WindowWidth;
            int lastHeight = Console.WindowHeight;

            while (ToBool(syncHash["Running"])) {
                int width = Console.WindowWidth;
                int height = Console.WindowHeight;

                if (width != lastWidth || height != lastHeight) {
                    Console.Clear();
                    lastWidth = width;
                    lastHeight = height;
                }

                // --- MID-SESSION DISCONNECT OVERLAY ---
                // Worker sets Disconnected=true and enters a reconnect loop while keeping Running=true.
                // We render a live overlay here (non-blocking) so the clock keeps ticking and
                // the user can press [Q] to quit via the normal key handler at the bottom of the loop.
                if (ToBool(syncHash["Disconnected"])) {
                    var sb2 = new StringBuilder();
                    sb2.Append("\x1b[H\x1b[0m");
                    int cw2 = width - 1;
                    string dBorder = new string('═', cw2);

                    // Header
                    sb2.Append("\x1b[31m" + dBorder + "\x1b[0m\n");
                    sb2.Append("\x1b[31m  ⚠  CONNECTION LOST\x1b[0m".PadRight(cw2 + 10) + "\n");
                    sb2.Append("\x1b[31m" + dBorder + "\x1b[0m\n");
                    sb2.Append("\n");

                    // Elapsed time
                    object disconnectTimeObj = Unwrap(syncHash["DisconnectTime"]);
                    string elapsedStr = "";
                    if (disconnectTimeObj is DateTime) {
                        var elapsed = DateTime.UtcNow - (DateTime)disconnectTimeObj;
                        elapsedStr = string.Format("{0}m {1}s", (int)elapsed.TotalMinutes, elapsed.Seconds);
                    }

                    // Spinner
                    string[] spinFrames = new string[] { "|", "/", "-", "\\" };
                    string spin = spinFrames[(int)(DateTime.UtcNow.Ticks / 2000000 % 4)];

                    int attempt = ToInt(syncHash["ReconnectAttempt"]);
                    string reconMsg = GetString(Unwrap(syncHash["ReconnectMessage"]));
                    // Word-wrap reconnect message
                    int mw = cw2 - 4;
                    string rem = reconMsg;
                    while (rem.Length > mw) {
                        int sp = rem.LastIndexOf(' ', mw); if (sp <= 0) sp = mw;
                        sb2.Append("\x1b[33m  " + rem.Substring(0, sp) + "\x1b[0m\n");
                        rem = rem.Substring(sp).TrimStart();
                    }
                    if (rem.Length > 0) sb2.Append("\x1b[33m  " + rem + "\x1b[0m\n");
                    sb2.Append("\n");

                    sb2.Append(string.Format("\x1b[36m  {0} Elapsed: {1}   Attempt: {2}\x1b[0m\n", spin, elapsedStr, attempt));
                    sb2.Append("\n");
                    sb2.Append("\x1b[90m" + new string('─', cw2) + "\x1b[0m\n");
                    sb2.Append("\x1b[32m  Waiting for host to come back online...\x1b[0m\n");
                    sb2.Append("\n");
                    sb2.Append("\x1b[40m\x1b[31m  [Q] Quit \x1b[0m\n");

                    // Pad remaining lines
                    int linesWritten = 13;
                    for (int pad = linesWritten; pad < height - 1; pad++) sb2.Append(" ".PadRight(cw2) + "\n");

                    Console.Write(sb2.ToString());

                    // Handle [Q] non-blocking
                    if (Console.KeyAvailable) {
                        var ki = Console.ReadKey(true);
                        if (ki.Key == ConsoleKey.Q) {
                            syncHash["Running"] = false;
                        }
                    }
                    Thread.Sleep(250); // refresh 4x/sec while waiting
                    continue;
                }

                // --- STARTUP CRITICAL ERROR (initial connect failed, raised by worker before TUI painted) ---
                if (ToBool(syncHash["CriticalError"])) {
                    string lostErr = GetString(syncHash["Error"]);
                    Console.Clear();
                    Console.CursorVisible = false;
                    int cw = Console.WindowWidth;
                    string border = new string('═', Math.Max(0, cw - 1));
                    Console.ForegroundColor = ConsoleColor.Red;
                    Console.WriteLine(border);
                    Console.WriteLine("  CONNECTION FAILED".PadRight(cw - 1));
                    Console.WriteLine(border);
                    Console.ResetColor();
                    Console.WriteLine();
                    Console.ForegroundColor = ConsoleColor.Yellow;
                    int maxW = cw - 4;
                    string remaining = lostErr;
                    while (remaining.Length > maxW) {
                        int split = remaining.LastIndexOf(' ', maxW);
                        if (split <= 0) split = maxW;
                        Console.WriteLine("  " + remaining.Substring(0, split));
                        remaining = remaining.Substring(split).TrimStart();
                    }
                    if (remaining.Length > 0) Console.WriteLine("  " + remaining);
                    Console.ResetColor();
                    Console.WriteLine();
                    Console.ForegroundColor = ConsoleColor.DarkGray;
                    Console.WriteLine("  Press any key to exit...");
                    Console.ResetColor();
                    try { Console.ReadKey(true); } catch {}
                    break;
                }

                if (width < 95 || height < 20) {
                    Console.Clear();
                    Console.ForegroundColor = ConsoleColor.Red;
                    Console.WriteLine("Terminal too small. Min 95x20.");
                    Thread.Sleep(1000);
                    continue;
                }

                // Check speed test runspace completion
                if (speedTestPS != null && speedTestAsyncHandle != null && speedTestAsyncHandle.IsCompleted) {
                    try { speedTestPS.EndInvoke(speedTestAsyncHandle); } catch {}
                    try { speedTestPS.Dispose(); } catch {}
                    speedTestPS = null;
                    speedTestAsyncHandle = null;
                }

                // Check history runspace completion
                if (historyPS != null && historyAsyncHandle != null && historyAsyncHandle.IsCompleted) {
                    try {
                        var results = historyPS.EndInvoke(historyAsyncHandle);
                        historyList = new List<object>();
                        if (results != null) {
                            foreach (var item in results) {
                                historyList.Add(item);
                            }
                        }
                        syncHash["HistoryData"] = historyList;
                        syncHash["ActionStatus"] = "Loaded " + historyList.Count + " history entries.";
                    }
                    catch (Exception ex) {
                        syncHash["ActionStatus"] = "Error loading history: " + ex.Message;
                    }
                    finally {
                        try { historyPS.Dispose(); } catch {}
                        historyPS = null;
                        historyAsyncHandle = null;
                        loadingHistory = false;
                    }
                }

                // Smooth speed test progress calculation
                var st = syncHash["SpeedTest"] as IDictionary;
                if (st != null && ToBool(st["Running"])) {
                    string actPhase = GetString(st["ActivePhase"]);
                    if (actPhase == "Download" || actPhase == "Upload") {
                        if (st["PhaseStartTime"] is DateTime) {
                            DateTime startTime = (DateTime)st["PhaseStartTime"];
                            double elapsed = (DateTime.UtcNow - startTime).TotalSeconds;
                            double limit = ToNum(st["TimeoutSeconds"], 15);
                            double pct = Math.Min(95.0, (elapsed / limit) * 100.0);
                            st["ProgressPercent"] = pct;
                        }
                    }
                }

                // Sync background thread flags
                syncHash["UserModeActive"] = (activeMode == "Users");
                syncHash["ServiceModeActive"] = (activeMode == "Services" && !showServiceProps);
                syncHash["TaskModeActive"] = (activeMode == "Tasks" && !showTaskProps);
                syncHash["AppModeActive"] = (activeMode == "Apps");
                syncHash["HistoryModeActive"] = (activeMode == "History");

                // Trigger history query asynchronously when entering History tab
                if (activeMode == "History") {
                    if (historyList == null && !loadingHistory && historyConfigured) {
                        loadingHistory = true;
                        syncHash["ActionStatus"] = "Loading Browser History...";
                        historyList = new List<object>(); // Prevents double-triggering

                        try {
                            // Use GetString() to handle PSObject-wrapped strings from PowerShell hashtable
                            string bhScript = GetString(syncHash["BrowserHistoryScript"]);
                            string b64Path  = GetString(syncHash["SqliteB64Path"]);
                            if (!string.IsNullOrEmpty(bhScript)) {
                                try { if (historyPS != null) historyPS.Dispose(); } catch {}
                                historyPS = PowerShell.Create();
                                string prefixScript = string.Format("$global:OAD_SqliteB64Path = '{0}';\n", b64Path.Replace("'", "''"));
                                historyPS.AddScript(prefixScript + bhScript + string.Format("\nGet-BrowserHistory -ComputerName $args[0] -Credential $args[1] -AllUsers -Hours {0}", historyDays * 24));
                                historyPS.AddArgument(computerName);
                                historyPS.AddArgument(credential);
                                historyAsyncHandle = historyPS.BeginInvoke();
                            } else {
                                string dbg = GetString(syncHash["DebugLog"]);
                                if (string.IsNullOrEmpty(dbg)) dbg = "No path debug info available.";
                                syncHash["ActionStatus"] = "Error: Script not loaded";
                                syncHash["HistoryError"] = "BrowserHistoryScript failed to load into SyncHash.\n" + dbg;
                                loadingHistory = false;
                            }
                        } catch (Exception ex) {
                            syncHash["ActionStatus"] = "Error: " + ex.Message.Substring(0, Math.Min(60, ex.Message.Length));
                            syncHash["HistoryError"] = "Exception starting history query: " + ex.Message;
                            loadingHistory = false;
                        }
                    }
                }

                // Frame Width (Console buffer safety limit)
                int frameWidth = width - 1;

                // Dynamic Header & Footer Height Sizing
                object staticData = syncHash["StaticData"];
                int headerHeight = (staticData != null && GetProperty(staticData, "GpuName") != null) ? 10 : 9;
                if (diagnostics) headerHeight += 1;

                // Resolve Footer Items
                string[] footerItems = new string[0];
                if (activeMode == "Processes") {
                    footerItems = new string[] { "\x1b[36;1m[S]\x1b[0m Search", "\x1b[36;1m[1-6]\x1b[0m Sort", "\x1b[36;1m[K]\x1b[0m Kill", "\x1b[36;1m[<-/->]\x1b[0m Page", "\x1b[36;1m[P]\x1b[0m " + (paused ? "Resume" : "Pause"), "\x1b[36;1m[M]\x1b[0m Menu", "\x1b[36;1m[Q]\x1b[0m Quit" };
                } else if (activeMode == "Services") {
                    footerItems = new string[] { "\x1b[33;1m[S]\x1b[0m Search", "\x1b[33;1m[P]\x1b[0m Props", "\x1b[33;1m[T]\x1b[0m Start/Stop", "\x1b[33;1m[R]\x1b[0m Restart", "\x1b[33;1m[<-/->]\x1b[0m Page", "\x1b[33;1m[M]\x1b[0m Menu", "\x1b[33;1m[ESC]\x1b[0m Back" };
                } else if (activeMode == "Tasks") {
                    footerItems = new string[] { "\x1b[36;1m[S]\x1b[0m Search", "\x1b[36;1m[T]\x1b[0m Toggle Run", "\x1b[36;1m[P]\x1b[0m Props", "\x1b[36;1m[1-4]\x1b[0m Sort", "\x1b[36;1m[<-/->]\x1b[0m Page", "\x1b[36;1m[M]\x1b[0m Menu", "\x1b[36;1m[ESC]\x1b[0m Back" };
                } else if (activeMode == "Apps") {
                    footerItems = new string[] { "\x1b[32;1m[S]\x1b[0m Search", "\x1b[32;1m[1-5]\x1b[0m Sort", "\x1b[32;1m[<-/->]\x1b[0m Page", "\x1b[32;1m[M]\x1b[0m Menu", "\x1b[32;1m[ESC]\x1b[0m Back" };
                } else if (activeMode == "Users") {
                    footerItems = new string[] { "\x1b[35;1m[S]\x1b[0m Search", "\x1b[35;1m[L]\x1b[0m Logoff User", "\x1b[35;1m[<-/->]\x1b[0m Page", "\x1b[35;1m[M]\x1b[0m Menu", "\x1b[35;1m[ESC]\x1b[0m Back" };
                } else if (activeMode == "SpeedTest") {
                    if (ToBool(st["Running"])) {
                        footerItems = new string[] { "\x1b[33;1mTesting in progress... Please do not close or resize the terminal.\x1b[0m" };
                    } else {
                        footerItems = new string[] { "\x1b[36;1m[UpDown]\x1b[0m Select", "\x1b[36;1m[<-/->]\x1b[0m Adjust", "\x1b[36;1m[Enter]\x1b[0m Start", "\x1b[36;1m[M]\x1b[0m Menu", "\x1b[36;1m[ESC]\x1b[0m Back" };
                    }
                } else if (activeMode == "History") {
                    if (!historyConfigured)
                        footerItems = new string[] { "\x1b[94;1m[1]\x1b[0m 1d", "\x1b[94;1m[2]\x1b[0m 7d", "\x1b[94;1m[3]\x1b[0m 14d", "\x1b[94;1m[4]\x1b[0m 30d", "\x1b[94;1m[5]\x1b[0m 90d", "\x1b[94;1m[C]\x1b[0m Custom", "\x1b[94;1m[M]\x1b[0m Menu", "\x1b[94;1m[ESC]\x1b[0m Back" };
                    else
                        footerItems = new string[] { "\x1b[94;1m[S]\x1b[0m Search", "\x1b[94;1m[1-5]\x1b[0m Sort", "\x1b[94;1m[Enter]\x1b[0m Details", "\x1b[94;1m[R]\x1b[0m Change Days", "\x1b[94;1m[<-/->]\x1b[0m Page", "\x1b[94;1m[M]\x1b[0m Menu", "\x1b[94;1m[ESC]\x1b[0m Back" };
                }

                string singleLineFooter = " " + string.Join("  \x1b[90m│\x1b[0m  ", footerItems);
                int visSingleLen = GetVisibleLength(singleLineFooter);

                string footerLine1 = "";
                string footerLine2 = null;
                int footerLinesCount = 1;

                if (visSingleLen <= frameWidth || footerItems.Length <= 1) {
                    footerLine1 = singleLineFooter;
                } else {
                    footerLinesCount = 2;
                    int half = (int)Math.Ceiling(footerItems.Length / 2.0);
                    var r1 = new List<string>();
                    var r2 = new List<string>();
                    for (int fi = 0; fi < footerItems.Length; fi++) {
                        if (fi < half) r1.Add(footerItems[fi]);
                        else r2.Add(footerItems[fi]);
                    }
                    footerLine1 = " " + string.Join("  \x1b[90m│\x1b[0m  ", r1.ToArray());
                    footerLine2 = " " + string.Join("  \x1b[90m│\x1b[0m  ", r2.ToArray());
                }

                int totalFooterHeight = 1 + footerLinesCount; // 1 top separator + footerLinesCount menu text lines
                int maxAvailableRows = height - headerHeight - 2 - totalFooterHeight;
                if (maxAvailableRows < 1) maxAvailableRows = 1;
                int currentPageSize = useFixedPageSize ? Math.Min(defaultPageSize, maxAvailableRows) : maxAvailableRows;

                // --- BUILD BUFFER ---
                StringBuilder sb = new StringBuilder();
                sb.Append("\x1b[H\x1b[0m"); // Cursor to Home + full color reset to prevent first-row color bleed

                // --- RESOLVE DATA GRID ---
                List<object> listToRender = new List<object>();
                string[] colHeaders = new string[0];
                string[] colProps = new string[0];
                int[] colWidths = new int[0];
                string[] colAligns = new string[0];

                if (activeMode == "Processes") {
                    colHeaders = new string[] { "PID (1)", "Name (2)", "CPU(%) (3)", "RAM(MB) (4)", "Threads (5)", "Handles (6)" };
                    colProps = new string[] { "IDProcess", "Name", "PercentProcessorTime", "WorkingSet", "ThreadCount", "HandleCount" };
                    colWidths = new int[] { 9, Math.Max(10, frameWidth - 61), 11, 11, 11, 12 };
                    colAligns = new string[] { "-", "-", "", "", "", "" };
                    var raw = (paused ? frozenProcessList : GetProcessList(syncHash));
                    if (raw != null) {
                        if (!string.IsNullOrEmpty(filterText)) {
                            var serviceHostMap = syncHash["ServiceHostMap"] as IDictionary;
                            var processMap = syncHash["ProcessMap"] as IDictionary;
                            raw = raw.FindAll(p => {
                                string pNameStr = GetString(p, "Name");
                                if (pNameStr.IndexOf(filterText, StringComparison.OrdinalIgnoreCase) >= 0) return true;
                                int pidVal = GetInt(p, "IDProcess");
                                if (serviceHostMap != null && serviceHostMap.Contains(pidVal)) {
                                    string svcStr = GetServiceHostString(serviceHostMap[pidVal]);
                                    if (svcStr.IndexOf(filterText, StringComparison.OrdinalIgnoreCase) >= 0) return true;
                                }
                                if (processMap != null && processMap.Contains(pidVal)) {
                                    string procStr = GetString(processMap[pidVal]);
                                    if (procStr.IndexOf(filterText, StringComparison.OrdinalIgnoreCase) >= 0) return true;
                                }
                                return false;
                            });
                        }
                        listToRender = GetSortedList(raw, colProps[selColIndex], isDesc);
                    }
                }
                else if (activeMode == "Services") {
                    colHeaders = new string[] { "Status (1)", "Name (2)", "Display Name (3)", "Type (4)" };
                    colProps = new string[] { "Status", "Name", "DisplayName", "StartType" };
                    int avail = Math.Max(10, frameWidth - 26);
                    int nameW = avail / 2;
                    colWidths = new int[] { 11, nameW, avail - nameW, 10 };
                    colAligns = new string[] { "-", "-", "-", "-" };
                    var raw = GetServiceList(syncHash);
                    if (raw != null) {
                        if (!string.IsNullOrEmpty(filterText)) {
                            raw = raw.FindAll(s => GetString(s, "Name").IndexOf(filterText, StringComparison.OrdinalIgnoreCase) >= 0 || GetString(s, "DisplayName").IndexOf(filterText, StringComparison.OrdinalIgnoreCase) >= 0);
                        }
                        listToRender = GetSortedList(raw, colProps[selColIndex], isDesc);
                    }
                }
                else if (activeMode == "Tasks") {
                    colHeaders = new string[] { "State (1)", "Task Name (2)", "Last Run Time (3)", "Result (4)" };
                    colProps = new string[] { "State", "TaskName", "LastRunTime", "LastTaskResult" };
                    int avail = Math.Max(10, frameWidth - 27);
                    int nameW = (int)Math.Floor(avail * 0.55);
                    colWidths = new int[] { 11, nameW, avail - nameW, 11 };
                    colAligns = new string[] { "-", "-", "-", "-" };
                    var raw = GetTaskList(syncHash);
                    if (raw != null) {
                        if (!string.IsNullOrEmpty(filterText)) {
                            raw = raw.FindAll(t => GetString(t, "TaskName").IndexOf(filterText, StringComparison.OrdinalIgnoreCase) >= 0);
                        }
                        listToRender = GetSortedList(raw, colProps[selColIndex], isDesc);
                    }
                }
                else if (activeMode == "Apps") {
                    colHeaders = new string[] { "Name (1)", "Version (2)", "Publisher (3)", "Type (4)", "Date (5)" };
                    colProps = new string[] { "DisplayName", "DisplayVersion", "Publisher", "AppType", "InstallDate" };
                    int avail = Math.Max(20, frameWidth - 43);
                    int nameW = (int)Math.Floor(avail * 0.6);
                    colWidths = new int[] { nameW, 15, avail - nameW, 10, 12 };
                    colAligns = new string[] { "-", "-", "-", "-", "-" };
                    var raw = GetAppList(syncHash);
                    if (raw != null) {
                        if (!string.IsNullOrEmpty(filterText)) {
                            raw = raw.FindAll(a => GetString(a, "DisplayName").IndexOf(filterText, StringComparison.OrdinalIgnoreCase) >= 0);
                        }
                        listToRender = GetSortedList(raw, colProps[selColIndex], isDesc);
                    }
                }
                else if (activeMode == "Users") {
                    colHeaders = new string[] { "USER (1)", "SESSION (2)", "ID (3)", "STATE (4)", "IDLE (5)", "LOGON TIME (6)" };
                    colProps = new string[] { "UserName", "SessionName", "SessionId", "State", "IdleTime", "LogonTime" };
                    int logonW = Math.Max(10, frameWidth - 7 - 20 - 15 - 10 - 12 - 15);
                    colWidths = new int[] { 20, 15, 10, 12, 15, logonW };
                    colAligns = new string[] { "-", "-", "-", "-", "-", "-" };
                    var raw = GetUserList(syncHash);
                    if (raw != null) {
                        if (!string.IsNullOrEmpty(filterText)) {
                            raw = raw.FindAll(u => GetString(u, "UserName").IndexOf(filterText, StringComparison.OrdinalIgnoreCase) >= 0);
                        }
                        listToRender = GetSortedList(raw, colProps[selColIndex], isDesc);
                    }
                }
                else if (activeMode == "History") {
                    colHeaders = new string[] { "Time (1)", "User (2)", "Browser (3)", "Title (4)", "URL (5)" };
                    colProps = new string[] { "Time", "User", "Browser", "Title", "URL" };
                    int avail = Math.Max(20, frameWidth - 51);
                    int titleW = (int)Math.Floor(avail * 0.45);
                    int urlW = avail - titleW;
                    colWidths = new int[] { 22, 11, 12, titleW, urlW };
                    colAligns = new string[] { "-", "-", "-", "-", "-" };
                    
                    var raw = historyList;
                    if (raw != null) {
                        if (!string.IsNullOrEmpty(filterText)) {
                            raw = raw.FindAll(h => GetString(h, "Title").IndexOf(filterText, StringComparison.OrdinalIgnoreCase) >= 0 ||
                                                   GetString(h, "URL").IndexOf(filterText, StringComparison.OrdinalIgnoreCase) >= 0 ||
                                                   GetString(h, "User").IndexOf(filterText, StringComparison.OrdinalIgnoreCase) >= 0);
                        }
                        listToRender = GetSortedList(raw, colProps[selColIndex], isDesc);
                    }
                }


                // Grid stats paging calculations
                int totalCount = listToRender.Count;
                int maxPages = (int)Math.Ceiling((double)totalCount / currentPageSize);
                if (maxPages == 0) maxPages = 1;
                if (pageIndex >= maxPages) pageIndex = maxPages - 1;
                if (pageIndex < 0) pageIndex = 0;

                int itemsOnPage = currentPageSize;
                if ((pageIndex + 1) == maxPages) {
                    itemsOnPage = totalCount - (pageIndex * currentPageSize);
                }

                // Keep selectedRow clamped based on items on the current page
                if (selectedRow >= itemsOnPage) selectedRow = Math.Max(0, itemsOnPage - 1);

                // 1. Header Border and Text (Including Page Count)
                string themeColor = "\x1b[36;1m"; // Cyan default
                string themePill  = "\x1b[46;30;1m";
                if (activeMode == "Services") { themeColor = "\x1b[33;1m"; themePill = "\x1b[43;30;1m"; }
                else if (activeMode == "Tasks") { themeColor = "\x1b[36;1m"; themePill = "\x1b[46;30;1m"; }
                else if (activeMode == "Users") { themeColor = "\x1b[35;1m"; themePill = "\x1b[45;30;1m"; }
                else if (activeMode == "Apps") { themeColor = "\x1b[32;1m"; themePill = "\x1b[42;30;1m"; }
                else if (activeMode == "History") { themeColor = "\x1b[94;1m"; themePill = "\x1b[44;37;1m"; }

                string titlePage = "";
                if (activeMode != "SpeedTest") {
                    titlePage = string.Format("{0}/{1}", pageIndex + 1, maxPages);
                }
                
                string rawTitle = " OMNIADMIN  " + activeMode.ToUpper() + (string.IsNullOrEmpty(titlePage) ? "" : " [" + titlePage + "]") + (isLocal ? "" : " (" + computerName + ")");
                int headerPad = frameWidth - 8 - rawTitle.Length;
                if (headerPad < 0) headerPad = 0;

                sb.Append(themeColor + "┌─── " + "\x1b[1;97mOMNIADMIN\x1b[0m  " + themePill + " " + activeMode.ToUpper() + " \x1b[0m" + (string.IsNullOrEmpty(titlePage) ? "" : " " + themeColor + "[" + titlePage + "]\x1b[0m") + (isLocal ? "" : " \x1b[90m(" + computerName + ")\x1b[0m") + " " + themeColor + new string('─', headerPad) + "┐\x1b[0m\n");

                // 2. Stats Bar
                object sysData = syncHash["SysData"];
                if (staticData != null && sysData != null) {
                    string cpuName = GetString(staticData, "CpuName");
                    string cores = GetString(staticData, "Cores");
                    string ansiCPU = string.Format("\x1b[1mCPU\x1b[0m  {0} \x1b[90m│\x1b[0m {1} Cores", cpuName, cores);
                    sb.Append(FormatBoxLine(ansiCPU, frameWidth, themeColor));

                    if (GetProperty(staticData, "GpuName") != null) {
                        string gpuName = GetString(staticData, "GpuName");
                        string ansiGPU = string.Format("\x1b[1mGPU\x1b[0m  {0}", gpuName);
                        sb.Append(FormatBoxLine(ansiGPU, frameWidth, themeColor));
                    }

                    string totalRam = GetString(staticData, "TotalRam");
                    string bootTimeStr = GetString(staticData, "BootTime");
                    string uptimeStr = "";
                    DateTime bootTime;
                    if (DateTime.TryParse(bootTimeStr, out bootTime)) {
                        var span = DateTime.Now - bootTime;
                        uptimeStr = string.Format("{0}d {1}h {2}m", span.Days, span.Hours, span.Minutes);
                    }
                    string ansiRAM = string.Format("\x1b[1mRAM\x1b[0m  {0} GB Total \x1b[90m│\x1b[0m Uptime: {1}", totalRam, uptimeStr);
                    sb.Append(FormatBoxLine(ansiRAM, frameWidth, themeColor));

                    double cpuLoad = GetDouble(sysData, "CpuLoad");
                    double totalSysRam = GetDouble(sysData, "TotalRam");
                    double freeSysRam = GetDouble(sysData, "FreeRam");
                    double usedSysRam = totalSysRam - freeSysRam;
                    int ramPct = totalSysRam > 0 ? (int)Math.Round((usedSysRam / totalSysRam) * 100) : 0;

                    string cpuColor, ramColor;
                    string cpuBar = GetProgressBar((int)cpuLoad, 20, out cpuColor);
                    string ramBar = GetProgressBar(ramPct, 20, out ramColor);
                    
                    string ansiLoad1 = string.Format("\x1b[1mCPU\x1b[0m  {0}{1}\x1b[0m {2,3}%   \x1b[1mRAM\x1b[0m  {3}{4}\x1b[0m {5,3}%", cpuColor, cpuBar, (int)cpuLoad, ramColor, ramBar, ramPct);
                    sb.Append(FormatBoxLine(ansiLoad1, frameWidth, themeColor));

                    double diskLoad = GetDouble(sysData, "DiskLoad");
                    string diskColor;
                    string diskBar = GetProgressBar((int)diskLoad, 20, out diskColor);

                    if (GetProperty(staticData, "GpuName") != null) {
                        double gpuLoad = GetDouble(sysData, "GpuLoad");
                        string gpuColor;
                        string gpuBar = GetProgressBar((int)gpuLoad, 20, out gpuColor);
                        
                        string ansiLoad2 = string.Format("\x1b[1mGPU\x1b[0m  {0}{1}\x1b[0m {2,3}%  \x1b[1mDISK\x1b[0m  {3}{4}\x1b[0m {5,3}%", gpuColor, gpuBar, (int)gpuLoad, diskColor, diskBar, (int)diskLoad);
                        sb.Append(FormatBoxLine(ansiLoad2, frameWidth, themeColor));
                    } else {
                        string ansiLoad2 = string.Format("\x1b[1mDISK\x1b[0m  {0}{1}\x1b[0m {2,3}%", diskColor, diskBar, (int)diskLoad);
                        sb.Append(FormatBoxLine(ansiLoad2, frameWidth, themeColor));
                    }

                    string ansiNet = string.Format("\x1b[1mNET\x1b[0m  Up: {0} Mbps \x1b[90m│\x1b[0m Dn: {1} Mbps  \x1b[90m│\x1b[0m  \x1b[1mIO\x1b[0m  Write: {2} MB/s \x1b[90m│\x1b[0m Read: {3} MB/s", GetProperty(sysData, "UpMbps"), GetProperty(sysData, "DnMbps"), GetProperty(sysData, "DiskWrite"), GetProperty(sysData, "DiskRead"));
                    sb.Append(FormatBoxLine(ansiNet, frameWidth, themeColor));

                    int pCount = 0;
                    var procObj = GetProperty(sysData, "Processes");
                    if (procObj != null) {
                        var procColl = Unwrap(procObj) as ICollection;
                        if (procColl != null) pCount = procColl.Count;
                    }
                    int tCount = GetInt(sysData, "ThreadCount");
                    int uCount = 0;
                    var userDataList = Unwrap(syncHash["UserData"]) as ICollection;
                    if (userDataList != null) uCount = userDataList.Count;
                    string ansiSys = string.Format("\x1b[1mSYS\x1b[0m  Processes: {0} \x1b[90m│\x1b[0m Threads: {1} \x1b[90m│\x1b[0m Users: {2}", pCount, tCount, uCount);
                    sb.Append(FormatBoxLine(ansiSys, frameWidth, themeColor));

                    string actionStatus = GetString(syncHash["ActionStatus"]);
                    string error = GetString(syncHash["Error"]);
                    if (!string.IsNullOrEmpty(actionStatus)) {
                        string visSt = actionStatus.Length <= frameWidth - 4 ? actionStatus : actionStatus.Substring(0, frameWidth - 7) + "...";
                        string ansiSt = "\x1b[36;1m" + visSt + "\x1b[0m";
                        sb.Append(FormatBoxLine(ansiSt, frameWidth, themeColor));
                    } else if (!string.IsNullOrEmpty(error)) {
                        string visErr = error.Length <= frameWidth - 4 ? error : error.Substring(0, frameWidth - 7) + "...";
                        string ansiErr = "\x1b[31;1m" + visErr + "\x1b[0m";
                        sb.Append(FormatBoxLine(ansiErr, frameWidth, themeColor));
                    } else {
                        sb.Append(FormatBoxLine("", frameWidth, themeColor));
                    }
                } else {
                    int lines = (staticData != null && GetProperty(staticData, "GpuName") != null) ? 10 : 7;
                    for (int l = 0; l < lines; l++) {
                        sb.Append(FormatBoxLine("", frameWidth, themeColor));
                    }
                }
                sb.Append(themeColor + "└" + new string('─', frameWidth - 2) + "┘\x1b[0m\n");

                // --- DRAW VIEWPORT PAGE CONTENT ---
                if (activeMode == "SpeedTest") {
                    // Track lines drawn so we can pad exactly to fill (never overflow) the terminal.
                    // headerHeight already accounts for the stats section.
                    // Footer always takes 2 lines (separator + footer bar).
                    // So the speed test body can use at most: height - headerHeight - 2 lines.
                    int stBodyBudget = height - headerHeight - 2;
                    int stLinesDrawn = 0;

                    void AppendST(string line) { sb.Append(line); stLinesDrawn++; }

                    // Render Speed Test Form & Gauge
                    AppendST("  NETWORK SPEED TEST CONFIGURATION & RESULTS".PadRight(frameWidth) + "\n");
                    AppendST(" ".PadRight(frameWidth) + "\n");
                    AppendST("\x1b[90m" + new string('─', frameWidth) + "\x1b[0m\n");
                    AppendST("  SETTINGS".PadRight(frameWidth) + "\n");

                    // Row 0: Test Mode
                    string modeDisp = isLocal ? "Local Internet (Cloudflare)" : (GetString(st["TestMode"]) == "Remote" ? "< Remote Internet (Cloudflare) >" : "< Peer-to-Peer (P2P LAN) >");
                    string row0 = "    [1] Test Mode:   " + modeDisp;
                    AppendST(speedTestRowIndex == 0 ? string.Format("\x1b[30;47m{0}\x1b[0m", row0.PadRight(frameWidth)) + "\n" : (row0.PadRight(frameWidth) + "\n"));

                    // Row 1: Threads
                    string row1 = "    [2] Threads:     " + st["Threads"] + " (concurrent streams)";
                    AppendST(speedTestRowIndex == 1 ? string.Format("\x1b[30;47m{0}\x1b[0m", row1.PadRight(frameWidth)) + "\n" : (row1.PadRight(frameWidth) + "\n"));

                    // Row 2: Timeout
                    string row2 = "    [3] Timeout:     " + st["TimeoutSeconds"] + " seconds per phase";
                    AppendST(speedTestRowIndex == 2 ? string.Format("\x1b[30;47m{0}\x1b[0m", row2.PadRight(frameWidth)) + "\n" : (row2.PadRight(frameWidth) + "\n"));

                    int startButtonRow = 3;
                    if (!isLocal) {
                        // Row 3: P2P Port
                        string portDisp = GetString(st["TestMode"]) == "P2P" ? (GetString(st["Port"]) == "" ? "5201" : GetString(st["Port"])) : "N/A (Only for P2P Mode)";
                        string row3 = "    [4] P2P Port:    " + portDisp;
                        string fgColor = GetString(st["TestMode"]) == "P2P" ? "" : "\x1b[90m";
                        AppendST(speedTestRowIndex == 3 ? string.Format("\x1b[30;47m{0}\x1b[0m", row3.PadRight(frameWidth)) + "\n" : (fgColor + row3.PadRight(frameWidth) + "\x1b[0m\n"));
                        AppendST(" ".PadRight(frameWidth) + "\n");
                        startButtonRow = 4;
                    }

                    // Start Button Row
                    string btn = "                     [   S T A R T   T E S T   ]";
                    AppendST(speedTestRowIndex == startButtonRow ? string.Format("\x1b[30;47m{0}\x1b[0m", btn.PadRight(frameWidth)) + "\n" : (btn.PadRight(frameWidth) + "\n"));
                    AppendST(" ".PadRight(frameWidth) + "\n");
                    AppendST("  STATUS & RESULTS".PadRight(frameWidth) + "\n");

                    // Status / Phase
                    string phaseDisp = "Idle";
                    string phaseColor = "\x1b[90m";
                    if (ToBool(st["Running"])) {
                        phaseColor = "\x1b[36m"; // Cyan
                        string activePhase = GetString(st["ActivePhase"]);
                        if (activePhase == "Latency") phaseDisp = "Testing Latency (Target: " + computerName + ")...";
                        else if (activePhase == "Download") phaseDisp = "Testing Download...";
                        else if (activePhase == "Upload") phaseDisp = "Testing Upload...";
                    } else {
                        string activePhase = GetString(st["ActivePhase"]);
                        if (activePhase == "Done") { phaseDisp = "Completed!"; phaseColor = "\x1b[32m"; }
                        else if (activePhase == "Error") {
                            var res = st["Results"] as IDictionary;
                            // Truncate error to single line so it doesn't overflow the layout
                            string errMsg = (res["Error"] != null) ? res["Error"].ToString() : "";
                            int maxErrLen = frameWidth - 16;
                            if (errMsg.Length > maxErrLen) errMsg = errMsg.Substring(0, maxErrLen) + "...";
                            // Strip newlines so a multi-line error doesn't push the layout down
                            errMsg = errMsg.Replace("\r", " ").Replace("\n", " ");
                            phaseDisp = "Failed: " + errMsg;
                            phaseColor = "\x1b[31m";
                        }
                    }
                    string phaseText = "    Phase:    " + phaseDisp;
                    AppendST(phaseColor + phaseText.PadRight(frameWidth) + "\x1b[0m\n");

                    // Progress Bar
                    if (ToBool(st["Running"])) {
                        double pct = ToNum(st["ProgressPercent"], 0);
                        int pChars = (int)Math.Round((pct / 100.0) * 25);
                        pChars = Math.Min(25, Math.Max(0, pChars));
                        string pBar = new string('#', pChars) + new string('.', 25 - pChars);
                        string progText = string.Format("    Progress: [{0}] {1}%", pBar, (int)Math.Round(pct));
                        AppendST("\x1b[36m" + progText.PadRight(frameWidth) + "\x1b[0m\n");
                    } else {
                        string progText = "    Progress: --";
                        AppendST("\x1b[90m" + progText.PadRight(frameWidth) + "\x1b[0m\n");
                    }

                    // Dynamic P2P Labels and Padding Alignments
                    string labelLat = "    Latency:";
                    string labelDl = (GetString(st["TestMode"]) == "P2P") ? ("    From " + computerName + ":") : "    Download:";
                    string labelUl = (GetString(st["TestMode"]) == "P2P") ? ("    To " + computerName + ":") : "    Upload:";
                    int maxL = Math.Max(labelLat.Length, Math.Max(labelDl.Length, labelUl.Length)) + 1;

                    // Results readings
                    var results = st["Results"] as IDictionary;
                    string latVal = "-- ms";
                    string latColor = "\x1b[90m";
                    if (results["Latency"] != null) { latVal = results["Latency"] + " ms"; latColor = "\x1b[32m"; }
                    string latText = labelLat.PadRight(maxL) + latVal;
                    AppendST(latColor + latText.PadRight(frameWidth) + "\x1b[0m\n");

                    string dlVal = "-- Mbps";
                    string dlColor = "\x1b[90m";
                    if (results["Download"] != null) {
                        double mbps = ToNum(results["Download"]);
                        dlVal = mbps >= 1000 ? (Math.Round(mbps / 1000.0, 2).ToString() + " Gbps") : (Math.Round(mbps, 2).ToString() + " Mbps");
                        dlColor = "\x1b[32m";
                    }
                    string dlText = labelDl.PadRight(maxL) + dlVal;
                    AppendST(dlColor + dlText.PadRight(frameWidth) + "\x1b[0m\n");

                    string ulVal = "-- Mbps";
                    string ulColor = "\x1b[90m";
                    if (results["Upload"] != null) {
                        double mbps = ToNum(results["Upload"]);
                        ulVal = mbps >= 1000 ? (Math.Round(mbps / 1000.0, 2).ToString() + " Gbps") : (Math.Round(mbps, 2).ToString() + " Mbps");
                        ulColor = "\x1b[32m";
                    }
                    string ulText = labelUl.PadRight(maxL) + ulVal;
                    AppendST(ulColor + ulText.PadRight(frameWidth) + "\x1b[0m\n");

                    // Pad remaining lines exactly to fill available space — never overflow
                    for (int x = stLinesDrawn; x < stBodyBudget; x++) {
                        sb.Append(" ".PadRight(frameWidth) + "\n");
                    }
                } 
                else {
                    // Draw Table Grids (Processes, Services, Tasks, Apps, Users)
                    
                    // Render Columns Headers
                    sb.Append("  ");
                    for (int i = 0; i < colHeaders.Length; i++) {
                        string hText = colHeaders[i];
                        if (i == selColIndex) {
                            string arrow = isDesc ? " v" : " ^";
                            hText += arrow;
                        }
                        if (hText.Length > colWidths[i]) hText = hText.Substring(0, colWidths[i]);
                        
                        string fmt = "{0," + colAligns[i] + colWidths[i] + "}";
                        string cell = string.Format(fmt, hText);
                        
                        if (i == selColIndex) sb.Append(string.Format("{0}{1}\x1b[0m", themePill, cell));
                        else sb.Append(string.Format("\x1b[1;37m{0}\x1b[0m", cell));
                        
                        if (i < colHeaders.Length - 1) {
                            sb.Append("\x1b[90m│\x1b[0m");
                        }
                    }
                    sb.Append("\n");
                    sb.Append("\x1b[90m" + new string('\u2500', frameWidth) + "\x1b[0m\n");

                    // --- HISTORY TIMEFRAME SELECTOR (replaces grid rows when not yet configured) ---
                    if (activeMode == "History" && !historyConfigured) {
                        sb.Append(("  \x1b[97mSelect history timeframe to load:\x1b[0m").PadRight(frameWidth) + "\n");
                        sb.Append(" ".PadRight(frameWidth) + "\n");
                        string[] presets = new string[] {
                            "  [1]  1 Day     (last 24 hours)",
                            "  [2]  7 Days    (last week)",
                            "  [3]  14 Days   (last 2 weeks)",
                            "  [4]  30 Days   (last month)",
                            "  [5]  90 Days   (last 3 months)",
                            "  [C]  Custom... (enter any number of days)"
                        };
                        foreach (string opt in presets) {
                            sb.Append(("  \x1b[36m" + opt + "\x1b[0m").PadRight(frameWidth) + "\n");
                        }
                        sb.Append(" ".PadRight(frameWidth) + "\n");
                        sb.Append(("  \x1b[90mPress a number key or [C] for custom entry.\x1b[0m").PadRight(frameWidth) + "\n");
                        int selFiller = maxAvailableRows - presets.Length - 4;
                        for (int x = 0; x < selFiller; x++) sb.Append(" ".PadRight(frameWidth) + "\n");
                    } else {

                    // Render grid items
                    int skip = pageIndex * currentPageSize;
                    int rowsDrawn = 0;
                    for (int i = 0; i < currentPageSize; i++) {
                        int idx = skip + i;
                        if (idx < totalCount) {
                            object item = listToRender[idx];
                            string line = "";
                            string fg = "\x1b[37m"; // White
                            
                            if (activeMode == "Processes") {
                                string pName = GetString(item, "Name");
                                string baseName = System.Text.RegularExpressions.Regex.Replace(pName, @"#\d+$", "");
                                int pid = GetInt(item, "IDProcess");

                                pName = baseName;
                                if (baseName.StartsWith("svchost", StringComparison.OrdinalIgnoreCase)) {
                                    var serviceHostMap = syncHash["ServiceHostMap"] as IDictionary;
                                    if (serviceHostMap != null && serviceHostMap.Contains(pid)) {
                                        string servicesStr = GetServiceHostString(serviceHostMap[pid]);
                                        if (!string.IsNullOrEmpty(servicesStr)) {
                                            pName = string.Format("{0} ({1})", baseName, servicesStr);
                                        }
                                    }
                                }
                                else if (baseName.IndexOf("webview", StringComparison.OrdinalIgnoreCase) >= 0 || baseName.IndexOf("msedge", StringComparison.OrdinalIgnoreCase) >= 0) {
                                    string desc = "";
                                    var processMap = syncHash["ProcessMap"] as IDictionary;
                                    if (processMap != null && processMap.Contains(pid)) {
                                        desc = GetString(processMap[pid]);
                                    }
                                    if (string.IsNullOrEmpty(desc) || desc.Equals(baseName, StringComparison.OrdinalIgnoreCase)) {
                                        desc = "Microsoft Edge WebView2";
                                    }
                                    pName = string.Format("{0} ({1})", baseName, desc);
                                }
                                else {
                                    var processMap = syncHash["ProcessMap"] as IDictionary;
                                    if (processMap != null && processMap.Contains(pid)) {
                                        string desc = GetString(processMap[pid]);
                                        if (!string.IsNullOrEmpty(desc) && !desc.Equals(baseName, StringComparison.OrdinalIgnoreCase)) {
                                            pName = string.Format("{0} ({1})", baseName, desc);
                                        }
                                    }
                                }
                                if (pName.Length > colWidths[1]) pName = pName.Substring(0, colWidths[1]);
                                double rawCpu = GetDouble(item, "PercentProcessorTime");
                                int coreCount = ToInt(syncHash["Cores"], 1);
                                double cpuVal = Math.Round(rawCpu / coreCount, 1);
                                if (cpuVal > 100) cpuVal = 100.0;
                                if (cpuVal < 0) cpuVal = 0.0;
                                
                                double memBytes = GetDouble(item, "WorkingSet");
                                double memVal = Math.Round(memBytes / (1024.0 * 1024.0), 0);
                                
                                string icon = cpuVal > 50 ? "!" : (cpuVal > 25 ? "*" : " ");
                                string pidStr = icon + GetString(item, "IDProcess");
                                if (pidStr.Length > colWidths[0]) pidStr = pidStr.Substring(0, colWidths[0]);

                                string cpuStr = string.Format("{0:0.0}", cpuVal);
                                if (cpuStr.Length > colWidths[2]) cpuStr = cpuStr.Substring(0, colWidths[2]);

                                string memStr = memVal.ToString();
                                if (memStr.Length > colWidths[3]) memStr = memStr.Substring(0, colWidths[3]);

                                string thrStr = GetString(item, "ThreadCount");
                                if (thrStr.Length > colWidths[4]) thrStr = thrStr.Substring(0, colWidths[4]);

                                string hndStr = GetString(item, "HandleCount");
                                if (hndStr.Length > colWidths[5]) hndStr = hndStr.Substring(0, colWidths[5]);

                                line = string.Format("  {0,-" + colWidths[0] + "}│{1,-" + colWidths[1] + "}│{2," + colWidths[2] + "}│{3," + colWidths[3] + "}│{4," + colWidths[4] + "}│{5," + colWidths[5] + "}",
                                    pidStr, pName, cpuStr, memStr, thrStr, hndStr);
                                    
                                if (cpuVal > 75) fg = "\x1b[31m"; // Red
                                else if (cpuVal > 50) fg = "\x1b[33m"; // Yellow
                                else if (cpuVal > 25) fg = "\x1b[36m"; // Cyan
                                else fg = "\x1b[90m"; // Gray
                                
                                if (paused && i == selectedRow) {
                                    sb.Append(string.Format("\x1b[48;5;24m\x1b[97;1m▶ {0}\x1b[0m", line.Substring(2).PadRight(frameWidth - 2)) + "\n");
                                } else {
                                    sb.Append(string.Format("{0}{1}\x1b[0m", fg, line.PadRight(frameWidth)) + "\n");
                                }
                            }
                            else if (activeMode == "Services") {
                                string status = GetString(item, "Status");
                                string sName = GetString(item, "Name");
                                if (sName.Length > colWidths[1]) sName = sName.Substring(0, colWidths[1]);
                                string dName = GetString(item, "DisplayName");
                                if (dName.Length > colWidths[2]) dName = dName.Substring(0, colWidths[2]);
                                
                                string statusStr = status;
                                if (statusStr.Length > colWidths[0]) statusStr = statusStr.Substring(0, colWidths[0]);
                                string startTypeStr = GetString(item, "StartType");
                                if (startTypeStr.Length > colWidths[3]) startTypeStr = startTypeStr.Substring(0, colWidths[3]);

                                line = string.Format("  {0,-" + colWidths[0] + "}│{1,-" + colWidths[1] + "}│{2,-" + colWidths[2] + "}│{3,-" + colWidths[3] + "}",
                                    statusStr, sName, dName, startTypeStr);
                                
                                if (status == "Running") fg = "\x1b[32m"; // Green
                                else if (status == "Stopped") fg = "\x1b[31m"; // Red
                                else fg = "\x1b[33m"; // Yellow
                                
                                if (i == selectedRow) {
                                    sb.Append(string.Format("\x1b[48;5;24m\x1b[97;1m▶ {0}\x1b[0m", line.Substring(2).PadRight(frameWidth - 2)) + "\n");
                                } else {
                                    sb.Append(string.Format("{0}{1}\x1b[0m", fg, line.PadRight(frameWidth)) + "\n");
                                }
                            }
                            else if (activeMode == "Tasks") {
                                string state = GetString(item, "State");
                                string tName = GetString(item, "TaskName");
                                if (tName.Length > colWidths[1]) tName = tName.Substring(0, colWidths[1]);
                                string rawTime = GetString(item, "LastRunTime");
                                string last = "--";
                                DateTime time;
                                if (DateTime.TryParse(rawTime, out time)) {
                                    last = time.ToString("MM/dd HH:mm");
                                }
                                string res = GetString(item, "LastTaskResult");
                                
                                string stateStr = state;
                                if (stateStr.Length > colWidths[0]) stateStr = stateStr.Substring(0, colWidths[0]);
                                string resStr = res;
                                if (resStr.Length > colWidths[3]) resStr = resStr.Substring(0, colWidths[3]);

                                line = string.Format("  {0,-" + colWidths[0] + "}│{1,-" + colWidths[1] + "}│{2,-" + colWidths[2] + "}│{3,-" + colWidths[3] + "}",
                                    stateStr, tName, last, resStr);
                                    
                                if (state == "Running") fg = "\x1b[32m"; // Green
                                else if (state == "Ready") fg = "\x1b[37m"; // White
                                else fg = "\x1b[90m"; // Gray
                                
                                if (i == selectedRow && !showTaskProps) {
                                    sb.Append(string.Format("\x1b[48;5;24m\x1b[97;1m▶ {0}\x1b[0m", line.Substring(2).PadRight(frameWidth - 2)) + "\n");
                                } else {
                                    string resColor = (res == "0") ? "\x1b[32m" : "\x1b[31m"; // Green for 0, Red for others
                                    int sepIdx = line.LastIndexOf('│');
                                    if (sepIdx >= 0) {
                                        string baseLine = line.Substring(0, sepIdx + 1);
                                        string resultCell = line.Substring(sepIdx + 1).PadRight(frameWidth - sepIdx - 1);
                                        sb.Append(fg + baseLine + resColor + resultCell + "\x1b[0m\n");
                                    } else {
                                        sb.Append(fg + line.PadRight(frameWidth) + "\x1b[0m\n");
                                    }
                                }
                            }
                            else if (activeMode == "Apps") {
                                string aName = GetString(item, "DisplayName");
                                aName = aName.PadRight(colWidths[0]).Substring(0, colWidths[0]);
                                string ver = GetString(item, "DisplayVersion");
                                ver = ver.PadRight(colWidths[1]).Substring(0, colWidths[1]);
                                string pub = GetString(item, "Publisher");
                                pub = pub.PadRight(colWidths[2]).Substring(0, colWidths[2]);
                                string type = GetString(item, "AppType");
                                type = type.PadRight(colWidths[3]).Substring(0, colWidths[3]);
                                string date = GetString(item, "InstallDate");
                                date = date.PadRight(colWidths[4]).Substring(0, colWidths[4]);
                                
                                line = "  " + aName + "│" + ver + "│" + pub + "│" + type + "│" + date;
                                line = line.PadRight(frameWidth).Substring(0, frameWidth);
                                
                                if (i == selectedRow) {
                                    sb.Append(string.Format("\x1b[48;5;24m\x1b[97;1m▶ {0}\x1b[0m", line.Substring(2).PadRight(frameWidth - 2)) + "\n");
                                } else {
                                    sb.Append(string.Format("\x1b[37m{0}\x1b[0m", line) + "\n");
                                }
                            }
                            else if (activeMode == "Users") {
                                string uName = GetString(item, "UserName");
                                if (uName.Length > colWidths[0]) uName = uName.Substring(0, colWidths[0]);
                                string sName = GetString(item, "SessionName");
                                if (sName.Length > colWidths[1]) sName = sName.Substring(0, colWidths[1]);
                                string sid = GetString(item, "SessionId");
                                if (sid.Length > colWidths[2]) sid = sid.Substring(0, colWidths[2]);
                                string state = GetString(item, "State");
                                if (state.Length > colWidths[3]) state = state.Substring(0, colWidths[3]);
                                string idle = GetString(item, "IdleTime");
                                if (idle.Length > colWidths[4]) idle = idle.Substring(0, colWidths[4]);
                                string logon = GetString(item, "LogonTime");
                                if (logon.Length > colWidths[5]) logon = logon.Substring(0, colWidths[5]);
                                
                                line = string.Format("  {0,-" + colWidths[0] + "}│{1,-" + colWidths[1] + "}│{2,-" + colWidths[2] + "}│{3,-" + colWidths[3] + "}│{4,-" + colWidths[4] + "}│{5,-" + colWidths[5] + "}",
                                    uName, sName, sid, state, idle, logon);
                                if (line.Length > frameWidth) line = line.Substring(0, frameWidth);
                                
                                if (i == selectedRow) {
                                    sb.Append(string.Format("\x1b[48;5;24m\x1b[97;1m▶ {0}\x1b[0m", line.Substring(2).PadRight(frameWidth - 2)) + "\n");
                                } else {
                                    sb.Append(string.Format("\x1b[37m{0}\x1b[0m", line.PadRight(frameWidth)) + "\n");
                                }
                            }
                            else if (activeMode == "History") {
                                string rawTime = GetString(item, "Time");
                                string timeStr = "--";
                                DateTime timeVal;
                                if (DateTime.TryParse(rawTime, out timeVal)) {
                                    timeStr = timeVal.ToString("MM/dd/yyyy HH:mm:ss");
                                }
                                if (timeStr.Length > colWidths[0]) timeStr = timeStr.Substring(0, colWidths[0]);

                                string uName = GetString(item, "User");
                                if (uName.Length > colWidths[1]) uName = uName.Substring(0, colWidths[1]);

                                string browser = GetString(item, "Browser");
                                if (browser.Length > colWidths[2]) browser = browser.Substring(0, colWidths[2]);

                                string title = GetString(item, "Title");
                                if (title.Length > colWidths[3]) title = title.Substring(0, colWidths[3]);

                                string url = GetString(item, "URL");
                                if (url.Length > colWidths[4]) url = url.Substring(0, colWidths[4]);

                                line = string.Format("  {0,-" + colWidths[0] + "}│{1,-" + colWidths[1] + "}│{2,-" + colWidths[2] + "}│{3,-" + colWidths[3] + "}│{4,-" + colWidths[4] + "}",
                                    timeStr, uName, browser, title, url);
                                if (line.Length > frameWidth) line = line.Substring(0, frameWidth);

                                if (i == selectedRow) {
                                    sb.Append(string.Format("\x1b[48;5;24m\x1b[97;1m▶ {0}\x1b[0m", line.Substring(2).PadRight(frameWidth - 2)) + "\n");
                                } else {
                                    sb.Append(string.Format("\x1b[37m{0}\x1b[0m", line.PadRight(frameWidth)) + "\n");
                                }
                            }
                        } else {
                            sb.Append(" ".PadRight(frameWidth) + "\n");
                        }
                        rowsDrawn++;
                    }
                    
                    // Draw filler rows to maintain grid size exactly and push footer to bottom of screen.
                    int empty = maxAvailableRows - rowsDrawn;
                    string historyError = activeMode == "History" ? GetString(syncHash["HistoryError"]) : "";
                    if (!string.IsNullOrEmpty(historyError) && empty > 0) {
                        int lineW = frameWidth - 4;
                        // Split on literal "\n" (escaped) and real newlines
                        string[] paragraphs = historyError.Replace("\\n", "\n").Split('\n');
                        int linesWritten = 0;
                        foreach (string para in paragraphs) {
                            if (linesWritten >= empty) break;
                            if (string.IsNullOrEmpty(para)) {
                                sb.Append(" ".PadRight(frameWidth) + "\n");
                                linesWritten++;
                                continue;
                            }
                            string rem = para;
                            while (rem.Length > 0 && linesWritten < empty) {
                                string chunk = rem.Length <= lineW ? rem : rem.Substring(0, lineW);
                                rem = rem.Length <= lineW ? "" : rem.Substring(lineW);
                                sb.Append(("  \x1b[91m" + chunk + "\x1b[0m").PadRight(frameWidth) + "\n");
                                linesWritten++;
                            }
                        }
                        for (int x = linesWritten; x < empty; x++) {
                            sb.Append(" ".PadRight(frameWidth) + "\n");
                        }
                    } else if (empty > 0) {
                        for (int x = 0; x < empty; x++) {
                            sb.Append(" ".PadRight(frameWidth) + "\n");
                        }
                    }
                }
                }

                // 3. Footer Separator and Menu Bar
                sb.Append("\x1b[90m" + new string('─', frameWidth) + "\x1b[0m\n");

                if (footerLinesCount == 1) {
                    int pad1 = frameWidth - GetVisibleLength(footerLine1);
                    sb.Append(footerLine1 + new string(' ', Math.Max(0, pad1)));
                } else {
                    int pad1 = frameWidth - GetVisibleLength(footerLine1);
                    sb.Append(footerLine1 + new string(' ', Math.Max(0, pad1)) + "\n");
                    int pad2 = frameWidth - GetVisibleLength(footerLine2);
                    sb.Append(footerLine2 + new string(' ', Math.Max(0, pad2)));
                }

                // --- OVERLAYS AND DIALOG BOXES ---
                
                // 1. Service Properties Overlay
                if (showServiceProps && activeMode == "Services") {
                    var raw = GetServiceList(syncHash);
                    if (raw != null) {
                        if (!string.IsNullOrEmpty(filterText)) {
                            raw = raw.FindAll(s => GetString(s, "Name").IndexOf(filterText, StringComparison.OrdinalIgnoreCase) >= 0 || GetString(s, "DisplayName").IndexOf(filterText, StringComparison.OrdinalIgnoreCase) >= 0);
                        }
                        var sorted = GetSortedList(raw, colProps[selColIndex], isDesc);
                        int absIndex = (pageIndex * currentPageSize) + selectedRow;
                        if (absIndex < sorted.Count) {
                            var target = sorted[absIndex];
                            int boxW = 60, boxH = 12;
                            int startX = (width - boxW) / 2;
                            int startY = (height - boxH) / 2;

                            // Draw overlay frame into screen buffer using ANSI sequences
                            for (int y = 0; y <= boxH; y++) {
                                sb.Append(string.Format("\x1b[{0};{1}H", startY + y + 1, startX + 1));
                                sb.Append("\x1b[37;44m" + new string(' ', boxW) + "\x1b[0m");
                            }
                            
                            sb.Append(string.Format("\x1b[{0};{1}H\x1b[37;44mSERVICE DETAILS\x1b[0m", startY + 2, startX + 3));
                            sb.Append(string.Format("\x1b[{0};{1}H\x1b[37;44mName: {2}\x1b[0m", startY + 3, startX + 3, GetString(target, "Name")));
                            sb.Append(string.Format("\x1b[{0};{1}H\x1b[37;44mDisplay: {2}\x1b[0m", startY + 4, startX + 3, GetString(target, "DisplayName")));
                            sb.Append(string.Format("\x1b[{0};{1}H\x1b[37;44mStatus: {2}\x1b[0m", startY + 5, startX + 3, GetString(target, "Status")));
                            sb.Append(string.Format("\x1b[{0};{1}H\x1b[37;44mStart Type: {2}\x1b[0m", startY + 6, startX + 3, GetString(target, "StartType")));
                            sb.Append(string.Format("\x1b[{0};{1}H\x1b[37;44mCan Stop: {2}\x1b[0m", startY + 7, startX + 3, GetString(target, "CanStop")));
                            sb.Append(string.Format("\x1b[{0};{1}H\x1b[37;44mCan Shutdown: {2}\x1b[0m", startY + 8, startX + 3, GetString(target, "CanShutdown")));
                            sb.Append(string.Format("\x1b[{0};{1}H\x1b[37;44m[ESC] Close\x1b[0m", startY + 12, startX + 3));
                        }
                    }
                }

                // 2. Task Properties Overlay
                if (showTaskProps && activeMode == "Tasks") {
                    var raw = GetTaskList(syncHash);
                    if (raw != null) {
                        if (!string.IsNullOrEmpty(filterText)) {
                            raw = raw.FindAll(t => GetString(t, "TaskName").IndexOf(filterText, StringComparison.OrdinalIgnoreCase) >= 0);
                        }
                        var sorted = GetSortedList(raw, colProps[selColIndex], isDesc);
                        int absIndex = (pageIndex * currentPageSize) + selectedRow;
                        if (absIndex < sorted.Count) {
                            var target = sorted[absIndex];
                            int boxW = 70, boxH = 12;
                            int startX = (width - boxW) / 2;
                            int startY = (height - boxH) / 2;

                            for (int y = 0; y <= boxH; y++) {
                                sb.Append(string.Format("\x1b[{0};{1}H", startY + y + 1, startX + 1));
                                sb.Append("\x1b[37;46m" + new string(' ', boxW) + "\x1b[0m");
                            }

                            string trig = GetString(target, "TriggerType");
                            if (trig.Length > boxW - 10) trig = trig.Substring(0, boxW - 10);
                            string act = GetString(target, "ActionType");
                            if (act.Length > boxW - 10) act = act.Substring(0, boxW - 10);

                            sb.Append(string.Format("\x1b[{0};{1}H\x1b[37;46mTASK DETAILS\x1b[0m", startY + 2, startX + 3));
                            sb.Append(string.Format("\x1b[{0};{1}H\x1b[37;46mName: {2}\x1b[0m", startY + 3, startX + 3, GetString(target, "TaskName")));
                            sb.Append(string.Format("\x1b[{0};{1}H\x1b[37;46mRun:  {2}\x1b[0m", startY + 4, startX + 3, GetString(target, "LastRunTime")));
                            sb.Append(string.Format("\x1b[{0};{1}H\x1b[37;46mResult Code: {2}\x1b[0m", startY + 5, startX + 3, GetString(target, "LastTaskResult")));
                            sb.Append(string.Format("\x1b[{0};{1}H\x1b[37;46mTrig: {2}\x1b[0m", startY + 7, startX + 3, trig));
                            sb.Append(string.Format("\x1b[{0};{1}H\x1b[37;46mAction: {2}\x1b[0m", startY + 9, startX + 3, act));
                            sb.Append(string.Format("\x1b[{0};{1}H\x1b[37;46m[ESC] Close\x1b[0m", startY + 12, startX + 3));
                        }
                    }
                }

                // 3. History Row Detail Overlay
                if (showHistoryDetail && activeMode == "History") {
                    var rawH = historyList;
                    if (rawH != null && !string.IsNullOrEmpty(filterText)) {
                        rawH = rawH.FindAll(h => GetString(h, "Title").IndexOf(filterText, StringComparison.OrdinalIgnoreCase) >= 0 ||
                                               GetString(h, "URL").IndexOf(filterText, StringComparison.OrdinalIgnoreCase) >= 0 ||
                                               GetString(h, "User").IndexOf(filterText, StringComparison.OrdinalIgnoreCase) >= 0);
                    }
                    if (rawH != null) {
                        var sortedH = GetSortedList(rawH, colProps[selColIndex], isDesc);
                        int absIdx = (pageIndex * currentPageSize) + selectedRow;
                        if (absIdx < sortedH.Count) {
                            var item = sortedH[absIdx];

                            // Overlay dimensions — wide to fit URLs
                            int boxW = Math.Min(width - 4, 110);
                            int boxH = 14;
                            int startX = (width - boxW) / 2;
                            int startY = (height - boxH) / 2;
                            int innerW = boxW - 4; // usable content width inside padding

                            // Background fill
                            for (int y = 0; y <= boxH; y++) {
                                sb.Append(string.Format("\x1b[{0};{1}H", startY + y + 1, startX + 1));
                                sb.Append("\x1b[37;40m\x1b[44m" + new string(' ', boxW) + "\x1b[0m");
                            }

                            // Title bar
                            string detTitle = " HISTORY ENTRY DETAILS ";
                            int titleX = startX + (boxW - detTitle.Length) / 2;
                            sb.Append(string.Format("\x1b[{0};{1}H\x1b[97;44m{2}\x1b[0m", startY + 1, titleX, detTitle));

                            // Helper: render a labelled field with word-wrap across up to maxLines rows
                            // Returns the number of rows consumed
                            // Field rendering inline:
                            string fTime = GetString(item, "Time");
                            string fUser = GetString(item, "User");
                            string fBrowser = GetString(item, "Browser");
                            string fTitle = GetString(item, "Title");
                            string fUrl = GetString(item, "URL");

                            // Parse and reformat time
                            DateTime tVal;
                            if (DateTime.TryParse(fTime, out tVal)) fTime = tVal.ToString("yyyy-MM-dd HH:mm:ss");

                            int row = startY + 3;
                            // Fixed one-line fields
                            sb.Append(string.Format("\x1b[{0};{1}H\x1b[37;44m Time   : {2}\x1b[0m", row++, startX + 2, fTime));
                            sb.Append(string.Format("\x1b[{0};{1}H\x1b[37;44m User   : {2}\x1b[0m", row++, startX + 2, fUser));
                            sb.Append(string.Format("\x1b[{0};{1}H\x1b[37;44m Browser: {2}\x1b[0m", row++, startX + 2, fBrowser));
                            row++; // blank separator

                            // Title — word-wrap up to 2 lines
                            sb.Append(string.Format("\x1b[{0};{1}H\x1b[33;44m Title:\x1b[0m", row++, startX + 2));
                            string remTitle = fTitle;
                            int titleLines = 0;
                            while (remTitle.Length > 0 && titleLines < 2) {
                                string chunk = remTitle.Length <= innerW ? remTitle : remTitle.Substring(0, innerW);
                                remTitle = remTitle.Length <= innerW ? "" : remTitle.Substring(innerW);
                                sb.Append(string.Format("\x1b[{0};{1}H\x1b[37;44m {2}\x1b[0m", row++, startX + 2, chunk));
                                titleLines++;
                            }

                            row++; // blank separator

                            // URL — word-wrap up to 3 lines
                            sb.Append(string.Format("\x1b[{0};{1}H\x1b[33;44m URL:\x1b[0m", row++, startX + 2));
                            string remUrl = fUrl;
                            int urlLines = 0;
                            while (remUrl.Length > 0 && urlLines < 3) {
                                string chunk = remUrl.Length <= innerW ? remUrl : remUrl.Substring(0, innerW);
                                remUrl = remUrl.Length <= innerW ? "" : remUrl.Substring(innerW);
                                sb.Append(string.Format("\x1b[{0};{1}H\x1b[97;44m {2}\x1b[0m", row++, startX + 2, chunk));
                                urlLines++;
                            }

                            // Footer
                            sb.Append(string.Format("\x1b[{0};{1}H\x1b[90;44m [ESC] Close\x1b[0m", startY + boxH, startX + 2));
                        }
                    }
                }

                // 4. Main Menu Overlay (Uses decoupled menuSelectedIndex)
                if (showMainMenu) {
                    int boxW = 50, boxH = 13;
                    int startX = (width - boxW) / 2;
                    int startY = (height - boxH) / 2;

                    for (int y = 0; y <= boxH; y++) {
                        sb.Append(string.Format("\x1b[{0};{1}H", startY + y + 1, startX + 1));
                        sb.Append("\x1b[37;44m" + new string(' ', boxW) + "\x1b[0m");
                    }

                    sb.Append(string.Format("\x1b[{0};{1}H\x1b[37;44mMAIN MENU\x1b[0m", startY + 2, startX + 3));
                    
                    string[] items = new string[] {
                        "  [1] Live Processes View",
                        "  [2] Service Manager",
                        "  [3] Scheduled Tasks",
                        "  [4] Installed Applications",
                        "  [5] Active User Sessions",
                        "  [6] Speed Test Monitor",
                        "  [7] Browser History View"
                    };

                    for (int i = 0; i < items.Length; i++) {
                        sb.Append(string.Format("\x1b[{0};{1}H", startY + 4 + i, startX + 5));
                        if (i == menuSelectedIndex) {
                            sb.Append(string.Format("\x1b[30;47m{0}\x1b[0m", items[i].PadRight(boxW - 10)));
                        } else {
                            sb.Append(string.Format("\x1b[37;44m{0}\x1b[0m", items[i]));
                        }
                    }
                    sb.Append(string.Format("\x1b[{0};{1}H\x1b[37;44m[ESC] Close\x1b[0m", startY + boxH - 1, startX + 3));
                }

                // --- WRITE COMPLETED BUFFER TO SCREEN ---
                Console.Write(sb.ToString());

                // --- NON-BLOCKING USER INPUT HANDLER ---
                if (Console.KeyAvailable) {
                    var keyInfo = Console.ReadKey(true);
                    var key = keyInfo.Key;

                    // Clear redundant arrow buffers
                    if (key == ConsoleKey.LeftArrow || key == ConsoleKey.RightArrow || key == ConsoleKey.UpArrow || key == ConsoleKey.DownArrow) {
                        Thread.Sleep(10);
                        while (Console.KeyAvailable) Console.ReadKey(true);
                    }

                    if (key == ConsoleKey.Q) {
                        syncHash["Running"] = false;
                        break;
                    }

                    if (key == ConsoleKey.M) {
                        showMainMenu = true;
                        menuSelectedIndex = 0;
                    }

                    if (key == ConsoleKey.Escape) {
                        if (showMainMenu) showMainMenu = false;
                        else if (showServiceProps) showServiceProps = false;
                        else if (showTaskProps) showTaskProps = false;
                        else if (showHistoryDetail) showHistoryDetail = false;
                        else {
                            activeMode = "Processes";
                            showMainMenu = false;
                        }
                        Console.Clear();
                    }

                    // --- INPUT HANDLING: MAIN MENU ---
                    if (showMainMenu) {
                        if (key == ConsoleKey.UpArrow) {
                            menuSelectedIndex = (menuSelectedIndex - 1 + 7) % 7;
                        }
                        else if (key == ConsoleKey.DownArrow) {
                            menuSelectedIndex = (menuSelectedIndex + 1) % 7;
                        }
                        else if (key == ConsoleKey.Enter) {
                            if (menuSelectedIndex == 0) { activeMode = "Processes"; selColIndex = 2; isDesc = true; }
                            else if (menuSelectedIndex == 1) { activeMode = "Services"; selColIndex = 1; isDesc = false; }
                            else if (menuSelectedIndex == 2) { activeMode = "Tasks"; selColIndex = 1; isDesc = false; }
                            else if (menuSelectedIndex == 3) { activeMode = "Apps"; selColIndex = 0; isDesc = false; }
                            else if (menuSelectedIndex == 4) { activeMode = "Users"; selColIndex = 0; isDesc = false; }
                            else if (menuSelectedIndex == 5) { activeMode = "SpeedTest"; speedTestRowIndex = 0; }
                            else if (menuSelectedIndex == 6) { activeMode = "History"; selColIndex = 0; isDesc = true; }

                            showMainMenu = false;
                            selectedRow = 0;
                            pageIndex = 0;
                            filterText = "";
                            Console.Clear();
                        }
                        else if (key >= ConsoleKey.D1 && key <= ConsoleKey.D7) {
                            int choice = (int)key - (int)ConsoleKey.D1;
                            if (choice == 0) { activeMode = "Processes"; selColIndex = 2; isDesc = true; }
                            else if (choice == 1) { activeMode = "Services"; selColIndex = 1; isDesc = false; }
                            else if (choice == 2) { activeMode = "Tasks"; selColIndex = 1; isDesc = false; }
                            else if (choice == 3) { activeMode = "Apps"; selColIndex = 0; isDesc = false; }
                            else if (choice == 4) { activeMode = "Users"; selColIndex = 0; isDesc = false; }
                            else if (choice == 5) { activeMode = "SpeedTest"; speedTestRowIndex = 0; }
                            else if (choice == 6) { activeMode = "History"; selColIndex = 0; isDesc = true; }

                            showMainMenu = false;
                            selectedRow = 0;
                            pageIndex = 0;
                            filterText = "";
                            Console.Clear();
                        }
                    }
                    // --- INPUT HANDLING: SPEED TEST MODE ---
                    else if (activeMode == "SpeedTest") {
                        if (ToBool(st["Running"])) {
                            Thread.Sleep(50);
                            continue;
                        }

                        int startBtnIdx = isLocal ? 3 : 4;

                        if (key == ConsoleKey.UpArrow) {
                            speedTestRowIndex = (speedTestRowIndex - 1 + (startBtnIdx + 1)) % (startBtnIdx + 1);
                        }
                        else if (key == ConsoleKey.DownArrow) {
                            speedTestRowIndex = (speedTestRowIndex + 1) % (startBtnIdx + 1);
                        }
                        else if (key == ConsoleKey.LeftArrow || key == ConsoleKey.RightArrow) {
                            if (speedTestRowIndex == 0 && !isLocal) {
                                string currentMode = GetString(st["TestMode"]) == "Remote" ? "P2P" : "Remote";
                                st["TestMode"] = currentMode;
                            }
                            else if (speedTestRowIndex == 1) {
                                int thr = ToInt(st["Threads"], 8);
                                if (key == ConsoleKey.LeftArrow && thr > 1) st["Threads"] = thr - 1;
                                else if (key == ConsoleKey.RightArrow && thr < 64) st["Threads"] = thr + 1;
                            }
                            else if (speedTestRowIndex == 2) {
                                int timeout = ToInt(st["TimeoutSeconds"], 15);
                                if (key == ConsoleKey.LeftArrow && timeout > 5) st["TimeoutSeconds"] = timeout - 1;
                                else if (key == ConsoleKey.RightArrow && timeout < 120) st["TimeoutSeconds"] = timeout + 1;
                            }
                            else if (speedTestRowIndex == 3 && !isLocal && GetString(st["TestMode"]) == "P2P") {
                                int port = ToInt(st["Port"], 5201);
                                if (key == ConsoleKey.LeftArrow && port > 1024) st["Port"] = port - 1;
                                else if (key == ConsoleKey.RightArrow && port < 65535) st["Port"] = port + 1;
                            }
                        }
                        else if (key == ConsoleKey.Enter) {
                            int result;
                            if (speedTestRowIndex == 1) {
                                Console.CursorVisible = true;
                                Console.SetCursorPosition(0, height - 1);
                                Console.Write(" ENTER THREADS (1-64): ");
                                if (int.TryParse(Console.ReadLine(), out result) && result >= 1 && result <= 64) {
                                    st["Threads"] = result;
                                }
                                Console.CursorVisible = false;
                                Console.SetCursorPosition(0, 0); // reposition without clearing (avoids flicker)
                            }
                            else if (speedTestRowIndex == 2) {
                                Console.CursorVisible = true;
                                Console.SetCursorPosition(0, height - 1);
                                Console.Write(" ENTER TIMEOUT SECONDS (5-120): ");
                                if (int.TryParse(Console.ReadLine(), out result) && result >= 5 && result <= 120) {
                                    st["TimeoutSeconds"] = result;
                                }
                                Console.CursorVisible = false;
                                Console.SetCursorPosition(0, 0); // reposition without clearing (avoids flicker)
                            }
                            else if (speedTestRowIndex == 3 && !isLocal && GetString(st["TestMode"]) == "P2P") {
                                Console.CursorVisible = true;
                                Console.SetCursorPosition(0, height - 1);
                                Console.Write(" ENTER P2P PORT (1024-65535): ");
                                if (int.TryParse(Console.ReadLine(), out result) && result >= 1024 && result <= 65535) {
                                    st["Port"] = result;
                                }
                                Console.CursorVisible = false;
                                Console.SetCursorPosition(0, 0); // reposition without clearing (avoids flicker)
                            }
                            else if (speedTestRowIndex == startBtnIdx) {
                                st["Running"] = true;
                                st["ActivePhase"] = "Latency";
                                st["ProgressPercent"] = 0.0;
                                var res = st["Results"] as IDictionary;
                                res["Latency"] = null;
                                res["Download"] = null;
                                res["Upload"] = null;
                                res["Error"] = "";

                                speedTestPS = PowerShell.Create();
                                speedTestPS.AddScript(stWorkerScript)
                                           .AddArgument(syncHash)
                                           .AddArgument(initNetEngineScript)
                                           .AddArgument(computerName);
                                speedTestAsyncHandle = speedTestPS.BeginInvoke();
                            }
                        }
                    }
                    // --- INPUT HANDLING: GRID NAVIGATION PANELS ---
                    else {
                        if (showServiceProps || showTaskProps || showHistoryDetail) {
                            // While a detail panel is open, only process Escape (handled above)
                            Thread.Sleep(50);
                            continue;
                        }

                        if (activeMode == "History" && !historyConfigured) {
                            if (key == ConsoleKey.D1 || key == ConsoleKey.NumPad1) {
                                historyDays = 1; historyConfigured = true; historyList = null; syncHash["HistoryData"] = null; Console.Clear();
                            }
                            else if (key == ConsoleKey.D2 || key == ConsoleKey.NumPad2) {
                                historyDays = 7; historyConfigured = true; historyList = null; syncHash["HistoryData"] = null; Console.Clear();
                            }
                            else if (key == ConsoleKey.D3 || key == ConsoleKey.NumPad3) {
                                historyDays = 14; historyConfigured = true; historyList = null; syncHash["HistoryData"] = null; Console.Clear();
                            }
                            else if (key == ConsoleKey.D4 || key == ConsoleKey.NumPad4) {
                                historyDays = 30; historyConfigured = true; historyList = null; syncHash["HistoryData"] = null; Console.Clear();
                            }
                            else if (key == ConsoleKey.D5 || key == ConsoleKey.NumPad5) {
                                historyDays = 90; historyConfigured = true; historyList = null; syncHash["HistoryData"] = null; Console.Clear();
                            }
                            else if (key == ConsoleKey.C) {
                                Console.CursorVisible = true;
                                Console.SetCursorPosition(0, height - 1);
                                Console.Write("\x1b[36m ENTER CUSTOM DAYS (1-365): \x1b[0m");
                                string inputDays = Console.ReadLine();
                                int parsedDays;
                                if (int.TryParse(inputDays, out parsedDays) && parsedDays >= 1 && parsedDays <= 365) {
                                    historyDays = parsedDays;
                                    historyConfigured = true;
                                    historyList = null;
                                    syncHash["HistoryData"] = null;
                                }
                                Console.CursorVisible = false;
                                Console.SetCursorPosition(0, 0);
                                Console.Clear();
                            }
                            Thread.Sleep(50);
                            continue;
                        }

                        if (key == ConsoleKey.S) {
                            Console.CursorVisible = true;
                            Console.SetCursorPosition(0, height - 1);
                            Console.Write("\x1b[36m SEARCH: \x1b[0m");
                            string search = Console.ReadLine();
                            filterText = search != null ? search.Trim() : "";
                            pageIndex = 0;
                            selectedRow = 0;
                            Console.CursorVisible = false;
                            Console.SetCursorPosition(0, 0); // reposition without clearing (avoids flicker)
                        }
                        else if (key == ConsoleKey.UpArrow) {
                            if (selectedRow > 0) selectedRow--;
                        }
                        else if (key == ConsoleKey.DownArrow) {
                            if (selectedRow < (itemsOnPage - 1)) selectedRow++;
                        }
                        else if (key == ConsoleKey.LeftArrow) {
                            if (pageIndex > 0) { pageIndex--; selectedRow = 0; }
                        }
                        else if (key == ConsoleKey.RightArrow) {
                            if (pageIndex < (maxPages - 1)) { pageIndex++; selectedRow = 0; }
                        }
                        else if (key == ConsoleKey.Enter && activeMode == "History" && totalCount > 0) {
                            showHistoryDetail = true;
                        }
                        else if (key == ConsoleKey.P) {
                            if (activeMode == "Services") {
                                showServiceProps = true;
                            }
                            else if (activeMode == "Tasks") {
                                showTaskProps = true;
                            }
                            else if (activeMode == "Processes") {
                                Console.SetCursorPosition(0, 0); // reposition without clearing (avoids flicker)
                                paused = !paused;
                                selectedRow = 0; pageIndex = 0;
                                selColIndex = 2; isDesc = true;
                                syncHash["ActionStatus"] = ""; filterText = "";
                                if (paused) {
                                    var raw = GetProcessList(syncHash);
                                    frozenProcessList = new List<object>();
                                    if (raw != null) {
                                        foreach (var p in raw) frozenProcessList.Add(p);
                                    }
                                }
                            }
                        }
                        else if (key == ConsoleKey.T) {
                            int absIndex = (pageIndex * currentPageSize) + selectedRow;
                            if (absIndex < totalCount) {
                                var target = listToRender[absIndex];
                                if (activeMode == "Services") {
                                    string currentStatus = GetString(target, "Status");
                                    string action = (currentStatus == "Running") ? "Stop" : "Start";
                                    var queue = syncHash["ServiceQueue"];
                                    var actHash = new Hashtable();
                                    actHash["Name"] = GetString(target, "Name");
                                    actHash["Action"] = action;
                                    queue.GetType().GetMethod("Enqueue").Invoke(queue, new object[] { actHash });
                                }
                                else if (activeMode == "Tasks") {
                                    string tName = GetString(target, "TaskName");
                                    var queue = syncHash["TaskQueue"];
                                    queue.GetType().GetMethod("Enqueue").Invoke(queue, new object[] { tName });
                                }
                            }
                        }
                        else if (key == ConsoleKey.R && activeMode == "Services") {
                            int absIndex = (pageIndex * currentPageSize) + selectedRow;
                            if (absIndex < totalCount) {
                                var target = listToRender[absIndex];
                                var queue = syncHash["ServiceQueue"];
                                var actHash = new Hashtable();
                                actHash["Name"] = GetString(target, "Name");
                                actHash["Action"] = "Restart";
                                queue.GetType().GetMethod("Enqueue").Invoke(queue, new object[] { actHash });
                            }
                        }
                        else if (key == ConsoleKey.K && activeMode == "Processes" && paused) {
                            int absIndex = (pageIndex * currentPageSize) + selectedRow;
                            if (absIndex < totalCount) {
                                var target = listToRender[absIndex];
                                int pid = GetInt(target, "IDProcess");
                                var queue = syncHash["KillQueue"];
                                queue.GetType().GetMethod("Enqueue").Invoke(queue, new object[] { pid });
                            }
                        }
                        else if (key == ConsoleKey.L && activeMode == "Users") {
                            int absIndex = (pageIndex * currentPageSize) + selectedRow;
                            if (absIndex < totalCount) {
                                var target = listToRender[absIndex];
                                int sid = GetInt(target, "SessionId");
                                var queue = syncHash["LogoffQueue"];
                                queue.GetType().GetMethod("Enqueue").Invoke(queue, new object[] { sid });
                            }
                        }
                        else if (key == ConsoleKey.R && activeMode == "History" && !loadingHistory) {
                            historyList = null;
                            loadingHistory = false;
                            historyConfigured = false;
                            syncHash["HistoryData"] = null;
                            syncHash["HistoryError"] = null;
                            syncHash["ActionStatus"] = "";
                            Console.Clear();
                        }
                        else if (key >= ConsoleKey.D1 && key <= ConsoleKey.D7) {
                            int choice = (int)key - (int)ConsoleKey.D1;
                            if (choice < colHeaders.Length) {
                                if (selColIndex == choice) {
                                    isDesc = !isDesc;
                                } else {
                                    selColIndex = choice;
                                    isDesc = (activeMode == "Processes" && (choice == 2 || choice == 3)) || (activeMode == "History" && choice == 0);
                                }
                            }
                        }
                    }
                }

                Thread.Sleep(50);
            }
            
            try { if (speedTestPS != null) speedTestPS.Dispose(); } catch {}
            try { if (historyPS != null) historyPS.Dispose(); } catch {}

            Console.Write("\x1b[?1049l"); // Restore Main Screen Buffer
            Console.CursorVisible = true;
            Console.Clear();
        }
        
        public static List<object> GetProcessList(Hashtable syncHash) {
            var raw = Unwrap(syncHash["RawProcessList"]) as IEnumerable;
            if (raw == null) return new List<object>();
            var list = new List<object>();
            foreach (var item in raw) list.Add(item);
            return list;
        }
        public static List<object> GetServiceList(Hashtable syncHash) {
            var raw = Unwrap(syncHash["ServiceData"]) as IEnumerable;
            if (raw == null) return new List<object>();
            var list = new List<object>();
            foreach (var item in raw) list.Add(item);
            return list;
        }
        public static List<object> GetTaskList(Hashtable syncHash) {
            var raw = Unwrap(syncHash["TaskData"]) as IEnumerable;
            if (raw == null) return new List<object>();
            var list = new List<object>();
            foreach (var item in raw) list.Add(item);
            return list;
        }
        public static List<object> GetAppList(Hashtable syncHash) {
            var raw = Unwrap(syncHash["AppData"]) as IEnumerable;
            if (raw == null) return new List<object>();
            var list = new List<object>();
            foreach (var item in raw) list.Add(item);
            return list;
        }
        public static List<object> GetUserList(Hashtable syncHash) {
            var raw = Unwrap(syncHash["UserData"]) as IEnumerable;
            if (raw == null) return new List<object>();
            var list = new List<object>();
            foreach (var item in raw) list.Add(item);
            return list;
        }
        public static List<object> GetHistoryList(Hashtable syncHash) {
            var raw = Unwrap(syncHash["HistoryData"]) as IEnumerable;
            if (raw == null) return new List<object>();
            var list = new List<object>();
            foreach (var item in raw) list.Add(item);
            return list;
        }
    }
}
