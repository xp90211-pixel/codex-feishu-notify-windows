using System;
using System.IO;
using System.Text;
using System.Threading;

// Offline transport fixture: never opens a network connection.
public static class FakeLarkCli {
    public static int Main(string[] args) {
        string folder = Environment.GetEnvironmentVariable("CFN_TEST_CONTROL");
        if (String.IsNullOrEmpty(folder) || !Directory.Exists(folder)) return 95;
        string[] lines = new string[args.Length];
        for (int i = 0; i < args.Length; i++) lines[i] = Convert.ToBase64String(Encoding.UTF8.GetBytes(args[i]));
        File.WriteAllLines(Path.Combine(folder, "call-" + Guid.NewGuid().ToString("N") + ".txt"), lines, Encoding.UTF8);
        string mode = File.ReadAllText(Path.Combine(folder, "mode.txt")).Trim();
        Console.OutputEncoding = new UTF8Encoding(false);
        if (mode == "slow") Thread.Sleep(5000);
        if (mode == "hang") Thread.Sleep(15000);
        if (mode == "empty") return 0;
        if (mode == "malformed") { Console.WriteLine("not json"); return 0; }
        if (mode == "unknown") { Console.WriteLine("{\"hello\":true}"); return 0; }
        if (mode == "reject") { Console.WriteLine("{\"code\":999}"); return 0; }
        if (mode == "exit") { Console.WriteLine("{\"code\":0,\"data\":{\"message_id\":\"om_fixture\"}}"); return 1; }
        Console.Error.WriteLine("non-fatal fixture diagnostic");
        Console.WriteLine("{\"code\":0,\"data\":{\"message_id\":\"om_fixture\"}}");
        return 0;
    }
}
