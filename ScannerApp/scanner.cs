using System;
using System.Net.Sockets;
using System.Threading.Tasks;
using System.Collections.Generic;
using System.Threading;

class Program
{
    static async Task Main(string[] args)
    {
        Console.WriteLine("===== Scanner de Portas =====");

        // input do usuário
        Console.Write("Digite o IP ou o Hostname (Ex.: 192.168.1.1 ou localhost): ");
        string host = Console.ReadLine()?.Trim() ?? "localhost";

        Console.Write("Porta inicial (Ex.: 1): ");
        if (!int.TryParse(Console.ReadLine(), out int startPort)) startPort = 1;

        Console.Write("Porta final (Ex.: 100): ");
        if (!int.TryParse(Console.ReadLine(), out int endPort)) endPort = 100;

        if (startPort > endPort)
        {
            Console.WriteLine("Porta inicial não pode ser maior que a porta final.");
            return;
        }

        Console.WriteLine($"\nEscaneando {host} (portas {startPort}-{endPort})...\n");

        // limite de concorrência
        using var semaphore = new SemaphoreSlim(10);
        var tasks = new List<Task>();

        for (int port = startPort; port <= endPort; port++)
        {
            int currentPort = port;

            tasks.Add(Task.Run(async () =>
            {
                await semaphore.WaitAsync();
                try
                {
                    await ScanPort(host, currentPort);
                }
                finally
                {
                    semaphore.Release();
                }
            }));
        }

        await Task.WhenAll(tasks);

        Console.WriteLine("\nScan concluído!");
    }

    static async Task ScanPort(string host, int port)
    {
        try
        {
            using var client = new TcpClient();

            var connectTask = client.ConnectAsync(host, port);
            var delayTask = Task.Delay(500);

            var completedTask = await Task.WhenAny(connectTask, delayTask);

            if (completedTask == connectTask && client.Connected)
            {
                Console.WriteLine($"Porta {port}: ABERTA");
            }
        }
        catch (SocketException)
        {
            // ignorado
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Erro na porta {port}: {ex.Message}");
        }
    }
}
