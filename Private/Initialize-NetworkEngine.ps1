function Initialize-NetworkEngine {
    # Optimization: Unlock Connection Limit for PowerShell 5.1 (Legacy .NET)
    # Necessary to support >2 concurrent streams on older OS/PS versions.
    [System.Net.ServicePointManager]::DefaultConnectionLimit = 1000
    # Base TLS 1.2 which is supported by standard PS5.1
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

    # Try to add TLS 1.3 if the underlying .NET Framework supports it natively (.NET 4.8+)
    try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls13 } catch {}

    $cSharpCode = @"
using System;
using System.Diagnostics;
using System.Net.Http;
using System.Threading.Tasks;
using System.Threading;

public class NativeNetworkTest {
    private static readonly HttpClient client;

    static NativeNetworkTest() {
        client = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
        try {
            client.DefaultRequestHeaders.UserAgent.ParseAdd("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36");
        } catch {}
        
        uploadPayload = new byte[1 * 1024 * 1024]; // 1MB Chunk (moved from static constructor)
        new Random().NextBytes(uploadPayload);
    }

    // --- DOWNLOAD ENGINE ---
    public static double Download(string url, int threads, int timeoutSeconds) {
        var tasks = new Task<long>[threads]; 
        var sw = Stopwatch.StartNew();
        
        string activeUrl = url;
        string fallbackUrl = "https://download.sysinternals.com/files/SysinternalsSuite.zip";

        using (var cts = new CancellationTokenSource(TimeSpan.FromSeconds(timeoutSeconds))) {
            var token = cts.Token;
            for (int i = 0; i < threads; i++) {
                tasks[i] = Task.Run(async () => {
                    long totalBytes = 0;
                    while (!token.IsCancellationRequested) {
                        try {
                            string currentUrl = activeUrl;
                            using (var request = new HttpRequestMessage(HttpMethod.Get, currentUrl)) {
                                request.Version = new Version(1, 1); // Force HTTP/1.1
                                using (var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token)) {
                                    if (!response.IsSuccessStatusCode) {
                                        if (activeUrl == url) {
                                            activeUrl = fallbackUrl;
                                        }
                                        throw new HttpRequestException("HTTP non-success response status");
                                    }
                                    using (var stream = await response.Content.ReadAsStreamAsync()) {
                                        var buffer = new byte[81920]; 
                                        int bytesRead;
                                        while ((bytesRead = await stream.ReadAsync(buffer, 0, buffer.Length, token)) > 0) {
                                            totalBytes += bytesRead;
                                        }
                                    }
                                }
                            }
                        } 
                        catch (OperationCanceledException) { break; }
                        catch (Exception) { 
                            if (token.IsCancellationRequested) break;
                            Task.Delay(10).Wait(); // Transient error, avoid tight loop
                        }
                    }
                    return totalBytes;
                });
            }

            try { Task.WaitAll(tasks); } catch {} 
        }
        sw.Stop();

        long grandTotal = 0;
        foreach (var t in tasks) { 
            if (t.Status == TaskStatus.RanToCompletion) {
                grandTotal += t.Result; 
            }
        }

        return ((grandTotal * 8.0) / 1000000.0) / sw.Elapsed.TotalSeconds;
    }

    // --- UPLOAD ENGINE ---
    private static readonly byte[] uploadPayload;

    public static double Upload(string url, int threads, int timeoutSeconds) {
        var tasks = new Task<long>[threads]; 
        var sw = Stopwatch.StartNew();

        using (var cts = new CancellationTokenSource(TimeSpan.FromSeconds(timeoutSeconds))) {
            var token = cts.Token;
            for (int i = 0; i < threads; i++) {
                tasks[i] = Task.Run(async () => {
                    long totalBytesSent = 0; 
                    while (!token.IsCancellationRequested) {
                        try {
                            using (var request = new HttpRequestMessage(HttpMethod.Post, url)) {
                                request.Version = new Version(1, 1); // Force HTTP/1.1
                                request.Content = new ByteArrayContent(uploadPayload);
                                using (var response = await client.SendAsync(request, token)) {
                                    // Dispose drains and closes the response stream, returning the socket to the pool
                                }
                            }
                            totalBytesSent += uploadPayload.Length;
                        } 
                        catch (OperationCanceledException) { break; }
                        catch (Exception) { 
                            if (token.IsCancellationRequested) break;
                            Task.Delay(10).Wait(); 
                        }
                    }
                    return totalBytesSent;
                });
            }

            try { Task.WaitAll(tasks); } catch {}
        }
        sw.Stop();

        long grandTotal = 0;
        foreach (var t in tasks) { 
            if (t.Status == TaskStatus.RanToCompletion) {
                grandTotal += t.Result; 
            }
        }

        return ((grandTotal * 8.0) / 1000000.0) / sw.Elapsed.TotalSeconds;
    }
}
"@

    # Ensure the type isn't added twice if module is re-imported into the same session
    if (-not ("NativeNetworkTest" -as [type])) {
        Add-Type -TypeDefinition $cSharpCode -ReferencedAssemblies "System.Net.Http", "System.Net.Primitives"
    }

    # --- PEER-TO-PEER TCP ENGINE (Reverse-Connection Architecture) ---
    # LOCAL  = server + measurement point (accepts inbound from remote)
    # REMOTE = outbound worker / data pump (connects TO local — never blocked)
    $peerCSharpCode = @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;

public class PeerSpeedTest {
    private static readonly byte[] sendPayload;

    static PeerSpeedTest() {
        sendPayload = new byte[1 * 1024 * 1024]; // 1MB chunk
        new Random().NextBytes(sendPayload);
    }

    // ── LOCAL: MEASURE DOWNLOAD (remote → local) ────────────
    // Starts a listener, accepts N connections from the remote worker,
    // sends command 0x01 (telling remote to blast data), reads it, returns Mbps.
    public static double MeasureDownload(int port, int threads, int timeoutSeconds) {
        var listener = new TcpListener(IPAddress.Any, port);
        listener.Start();
        var clients = new List<TcpClient>();

        try {
            // Accept connections (remote worker connects outbound to us)
            var acceptDeadline = DateTime.UtcNow.AddSeconds(30);
            while (clients.Count < threads && DateTime.UtcNow < acceptDeadline) {
                var ar = listener.BeginAcceptTcpClient(null, null);
                if (ar.AsyncWaitHandle.WaitOne(500)) {
                    clients.Add(listener.EndAcceptTcpClient(ar));
                }
            }
            listener.Stop();
            if (clients.Count == 0) return 0;

            // Tell each remote worker to SEND data (download = remote→local)
            foreach (var c in clients) {
                c.ReceiveBufferSize = 1048576;
                c.GetStream().WriteByte(0x01);
            }

            // Read from all connections simultaneously and measure
            var tasks = new Task<long>[clients.Count];
            var sw = Stopwatch.StartNew();
            var deadline = TimeSpan.FromSeconds(timeoutSeconds);

            for (int i = 0; i < clients.Count; i++) {
                var stream = clients[i].GetStream();
                tasks[i] = Task.Run(() => {
                    long total = 0;
                    try {
                        var buf = new byte[131072];
                        while (sw.Elapsed < deadline) {
                            int n = stream.Read(buf, 0, buf.Length);
                            if (n == 0) break;
                            total += n;
                        }
                    } catch {}
                    return total;
                });
            }

            try { Task.WaitAll(tasks); } catch {}
            sw.Stop();

            long grand = 0;
            foreach (var t in tasks)
                if (t.Status == TaskStatus.RanToCompletion) grand += t.Result;

            return ((grand * 8.0) / 1000000.0) / sw.Elapsed.TotalSeconds;
        }
        finally {
            try { listener.Stop(); } catch {}
            foreach (var c in clients) { try { c.Close(); } catch {} }
        }
    }

    // ── LOCAL: MEASURE UPLOAD (local → remote) ──────────────
    // Same pattern but sends data TO the remote workers, measures write speed.
    public static double MeasureUpload(int port, int threads, int timeoutSeconds) {
        var listener = new TcpListener(IPAddress.Any, port);
        listener.Start();
        var clients = new List<TcpClient>();

        try {
            var acceptDeadline = DateTime.UtcNow.AddSeconds(30);
            while (clients.Count < threads && DateTime.UtcNow < acceptDeadline) {
                var ar = listener.BeginAcceptTcpClient(null, null);
                if (ar.AsyncWaitHandle.WaitOne(500)) {
                    clients.Add(listener.EndAcceptTcpClient(ar));
                }
            }
            listener.Stop();
            if (clients.Count == 0) return 0;

            // Tell each remote worker to RECEIVE data (upload = local→remote)
            foreach (var c in clients) {
                c.SendBufferSize = 1048576;
                c.GetStream().WriteByte(0x02);
            }

            var tasks = new Task<long>[clients.Count];
            var sw = Stopwatch.StartNew();
            var deadline = TimeSpan.FromSeconds(timeoutSeconds);

            for (int i = 0; i < clients.Count; i++) {
                var stream = clients[i].GetStream();
                tasks[i] = Task.Run(() => {
                    long total = 0;
                    try {
                        while (sw.Elapsed < deadline) {
                            stream.Write(sendPayload, 0, sendPayload.Length);
                            total += sendPayload.Length;
                        }
                    } catch {}
                    return total;
                });
            }

            try { Task.WaitAll(tasks); } catch {}
            sw.Stop();

            long grand = 0;
            foreach (var t in tasks)
                if (t.Status == TaskStatus.RanToCompletion) grand += t.Result;

            return ((grand * 8.0) / 1000000.0) / sw.Elapsed.TotalSeconds;
        }
        finally {
            try { listener.Stop(); } catch {}
            foreach (var c in clients) { try { c.Close(); } catch {} }
        }
    }

    // ── REMOTE WORKER: CONNECT OUTBOUND AND PUMP DATA ───────
    // Runs on the remote machine. Connects OUTBOUND to the local machine
    // (outbound is never blocked by firewalls). Reads a 1-byte command,
    // then either sends or receives data accordingly.
    //   0x01 = send data to local  (for local's download measurement)
    //   0x02 = read data from local (for local's upload measurement)
    public static void WorkerConnect(string host, int port, int connections, int lifetimeSeconds) {
        var tasks = new List<Task>();
        var cts = new CancellationTokenSource(TimeSpan.FromSeconds(lifetimeSeconds));
        var token = cts.Token;

        for (int i = 0; i < connections; i++) {
            tasks.Add(Task.Run(() => {
                while (!token.IsCancellationRequested) {
                    try {
                        using (var c = new TcpClient()) {
                            c.Connect(host, port);
                            c.SendBufferSize    = 1048576;
                            c.ReceiveBufferSize = 1048576;
                            var stream = c.GetStream();

                            // Wait for command from local
                            int cmd = stream.ReadByte();
                            if (cmd < 0) continue;

                            if (cmd == 0x03) {
                                // Kill signal received, abort all tasks instantly
                                cts.Cancel();
                                break;
                            } else if (cmd == 0x01) {
                                // Local wants to measure download: send data
                                while (!token.IsCancellationRequested) {
                                    stream.Write(sendPayload, 0, sendPayload.Length);
                                }
                            } else if (cmd == 0x02) {
                                // Local wants to measure upload: sink data
                                var buf = new byte[131072];
                                while (!token.IsCancellationRequested) {
                                    int n = stream.Read(buf, 0, buf.Length);
                                    if (n == 0) break;
                                }
                            }
                        }
                    } catch {
                        if (!token.IsCancellationRequested) Task.Delay(100).Wait();
                    }
                }
            }));
        }

        try { Task.WaitAll(tasks.ToArray()); } catch {}
        cts.Dispose();
    }

    // ── LOCAL: SEND KILL SIGNAL TO WORKERS ──────────────────
    public static void KillWorkers(int port) {
        var listener = new TcpListener(IPAddress.Any, port);
        try {
            listener.Start();
            var acceptDeadline = DateTime.UtcNow.AddMilliseconds(1500);
            while (DateTime.UtcNow < acceptDeadline) {
                if (listener.Pending()) {
                    using (var client = listener.AcceptTcpClient()) {
                        client.GetStream().WriteByte(0x03);
                        // We only need to tell one worker, it will cancel the shared token.
                        break; 
                    }
                }
                Thread.Sleep(50);
            }
        } catch {}
        finally {
            try { listener.Stop(); } catch {}
        }
    }
}
"@

    if (-not ("PeerSpeedTest" -as [type])) {
        Add-Type -TypeDefinition $peerCSharpCode
    }
}

