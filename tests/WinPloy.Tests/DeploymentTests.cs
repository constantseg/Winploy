using System.Collections.Concurrent;
using System.Security;
using WinPloy.Core.Deployment;
using WinPloy.Core.Models;
using PSCredential = System.Management.Automation.PSCredential;

namespace WinPloy.Tests;

public class PackageValidationTests
{
    [Theory]
    [InlineData("Git.Git", true)]
    [InlineData("Microsoft.VisualStudioCode", true)]
    [InlineData("Notepad++.Notepad++", true)]
    [InlineData(".Git", false)]
    [InlineData("Git Git", false)]
    [InlineData("custom:Git", false)]
    public void IsValidWingetId(string id, bool expected)
    {
        Assert.Equal(expected, PackageValidation.IsValidWingetId(id));
    }

    [Theory]
    [InlineData("Mon App (x64)", "custom:Mon_App_x64")]
    [InlineData("Éditeur v2.1", "custom:Éditeur_v2.1")]
    public void MakeCustomId(string name, string expected)
    {
        Assert.Equal(expected, PackageValidation.MakeCustomId(name));
    }

    [Fact]
    public void ValidateScriptPath_Rules()
    {
        const string root = @"\\srv\depot";
        static bool Exists(string _) => true;
        static bool Missing(string _) => false;

        Assert.Contains("chemin UNC requis", PackageValidation.ValidateScriptPath(@"C:\x\i.ps1", "Script", root, Exists));
        Assert.Contains("extension non supportée", PackageValidation.ValidateScriptPath(@"\\srv\depot\A\i.vbs", "Script", root, Exists));
        Assert.Contains("fichier introuvable", PackageValidation.ValidateScriptPath(@"\\srv\depot\A\i.ps1", "Script", root, Missing));
        Assert.Contains("sous-dossier dédié", PackageValidation.ValidateScriptPath(@"\\srv\depot\i.ps1", "Script", root + @"\", Exists));
        Assert.Null(PackageValidation.ValidateScriptPath(@"\\srv\depot\A\I.PS1", "Script", root, Exists));
        Assert.Null(PackageValidation.ValidateScriptPath(@"\\srv\depot\A\setup.MSI", "Script d'installation", root, Exists));
    }
}

public class CredentialCandidatesTests
{
    [Theory]
    [InlineData("admin", new[] { "admin", @"PC1\admin" })]
    [InlineData(@".\admin", new[] { @"PC1\admin" })]
    [InlineData(@"DOMAINE\admin", new[] { @"DOMAINE\admin" })]
    [InlineData("admin@domaine.local", new[] { "admin@domaine.local" })]
    public void BuildUserNames(string user, string[] expected)
    {
        Assert.Equal(expected, CredentialCandidates.BuildUserNames("PC1", user));
    }

    [Fact]
    public void Build_NoCredential_UsesCurrentContext()
    {
        Assert.Null(Assert.Single(CredentialCandidates.Build("PC1", null)));
    }

    [Fact]
    public void Build_KeepsPassword()
    {
        var password = new SecureString();
        password.AppendChar('x');
        var credential = new PSCredential("admin", password);

        var candidates = CredentialCandidates.Build("PC1", credential);

        Assert.Same(credential, candidates[0]);
        Assert.Equal(@"PC1\admin", candidates[1]!.UserName);
        Assert.Same(password, candidates[1]!.Password);
    }
}

public class FriendlyErrorsTests
{
    [Fact]
    public void Describe_KnownErrors()
    {
        Assert.StartsWith("Authentification WinRM impossible", FriendlyErrors.Describe("... 0x8009030E ..."));
        Assert.StartsWith("Accès refusé", FriendlyErrors.Describe("Connecting failed: Access is denied."));
        Assert.Equal("autre", FriendlyErrors.Describe(" autre "));
        Assert.Equal(FriendlyErrors.NoResultMessage, FriendlyErrors.Describe(""));
    }
}

public class HostOutcomeTests
{
    private static PackageResult Result(string statut, string message = "m")
        => new("PC1", "P", "Id", statut, message, DateTime.Now);

    [Fact]
    public void Compute_AllOk()
    {
        var outcome = HostOutcome.Compute([Result(ResultStatus.Ok), Result(ResultStatus.Ok)])!;

        Assert.Equal(HostStates.Ok, outcome.Etat);
        Assert.Equal("2 paquet(s) traité(s) avec succès.", outcome.Info);
    }

    [Fact]
    public void Compute_StoppedWins()
    {
        var outcome = HostOutcome.Compute([Result(ResultStatus.Stopped, "arrêt"), Result(ResultStatus.Failed)])!;

        Assert.Equal(HostStates.Stopped, outcome.Etat);
        Assert.Equal("arrêt", outcome.Info);
    }

    [Fact]
    public void Compute_Failure_CollapsesAndTruncatesMessage()
    {
        var outcome = HostOutcome.Compute([Result(ResultStatus.Ok), Result(ResultStatus.Failed, "a\r\n  b" + new string('x', 300))])!;

        Assert.Equal(HostStates.Failed, outcome.Etat);
        Assert.StartsWith("1/2 en échec : a b", outcome.Info);
        Assert.EndsWith("…", outcome.Info);
    }

    [Fact]
    public void Compute_NoResult_ReturnsNull()
    {
        Assert.Null(HostOutcome.Compute([]));
    }
}

public class DeploymentEngineTests
{
    private static DeploymentRequest Request(int targets, int parallel, TimeSpan? timeout = null) => new()
    {
        Targets = Enumerable.Range(1, targets).Select(i => $"PC{i}").ToList(),
        Packages = [CatalogueEntry.Create("Git.Git", "Git")!],
        Action = DeployAction.Install,
        PackageTimeoutMin = 30,
        MaxParallel = parallel,
        DepotRoot = @"\\srv\depot",
        JobTimeoutOverride = timeout,
    };

    [Fact]
    public void JobTimeout_IsPackageTimeoutTimesCountPlusFive()
    {
        Assert.Equal(TimeSpan.FromMinutes(35), Request(1, 1).JobTimeout);
    }

    [Fact]
    public async Task RunAsync_RespectsParallelLimit_AndReturnsResults()
    {
        var running = 0;
        var maxRunning = 0;
        var runner = new FakeRunner((computer, _) =>
        {
            var now = Interlocked.Increment(ref running);
            InterlockedMax(ref maxRunning, now);
            Thread.Sleep(50);
            Interlocked.Decrement(ref running);
            return [new TargetResult("Git.Git", "Git", ResultStatus.Ok, computer)];
        });
        var observer = new Observer();

        await new DeploymentEngine(runner).RunAsync(Request(6, 2), observer, CancellationToken.None);

        Assert.True(maxRunning <= 2);
        Assert.Equal(6, observer.Completed.Count);
        Assert.All(observer.Completed.Values, r => Assert.Equal(ResultStatus.Ok, r.Single().Statut));
    }

    [Fact]
    public async Task RunAsync_RunnerException_IsMadeReadable()
    {
        var runner = new FakeRunner((_, _) => throw new TargetException("Logon failure: unknown user name"));
        var observer = new Observer();

        await new DeploymentEngine(runner).RunAsync(Request(1, 1), observer, CancellationToken.None);

        var result = observer.Completed["PC1"].Single();
        Assert.Equal(ResultStatus.Failed, result.Statut);
        Assert.Equal(TargetResult.AllPackagesName, result.Name);
        Assert.StartsWith("Accès refusé", result.Message);
    }

    [Fact]
    public async Task RunAsync_Stop_MarksRunningAndPendingTargets()
    {
        var runner = new FakeRunner((_, token) =>
        {
            token.WaitHandle.WaitOne();
            token.ThrowIfCancellationRequested();
            return [];
        });
        var observer = new Observer();
        using var stop = new CancellationTokenSource();

        var run = new DeploymentEngine(runner).RunAsync(Request(3, 1), observer, stop.Token);
        await observer.FirstStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
        stop.Cancel();
        await run.WaitAsync(TimeSpan.FromSeconds(5));

        Assert.Equal(DeploymentEngine.StoppedByUserMessage, observer.Completed["PC1"].Single().Message);
        Assert.Equal(DeploymentEngine.NotStartedMessage, observer.Completed["PC2"].Single().Message);
        Assert.Equal(DeploymentEngine.NotStartedMessage, observer.Completed["PC3"].Single().Message);
        Assert.Null(observer.Elapsed["PC2"]);
    }

    [Fact]
    public async Task RunAsync_GlobalTimeout_FailsTarget()
    {
        var runner = new FakeRunner((_, token) =>
        {
            token.WaitHandle.WaitOne();
            return [];
        });
        var observer = new Observer();

        await new DeploymentEngine(runner).RunAsync(Request(1, 1, TimeSpan.FromMilliseconds(100)), observer, CancellationToken.None)
            .WaitAsync(TimeSpan.FromSeconds(5));

        var result = observer.Completed["PC1"].Single();
        Assert.Equal(ResultStatus.Failed, result.Statut);
        Assert.StartsWith("Délai global", result.Message);
    }

    private static void InterlockedMax(ref int target, int value)
    {
        int current;
        while (value > (current = Volatile.Read(ref target)) && Interlocked.CompareExchange(ref target, value, current) != current)
        {
        }
    }

    private sealed class FakeRunner(Func<string, CancellationToken, IReadOnlyList<TargetResult>> run) : ITargetRunner
    {
        public IReadOnlyList<TargetResult> Run(string computer, DeploymentRequest request, IProgress<TargetStatus> progress, CancellationToken cancellationToken)
            => run(computer, cancellationToken);
    }

    private sealed class Observer : IDeploymentObserver
    {
        public ConcurrentDictionary<string, IReadOnlyList<TargetResult>> Completed { get; } = new();

        public ConcurrentDictionary<string, TimeSpan?> Elapsed { get; } = new();

        public TaskCompletionSource FirstStarted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public void OnTargetStarted(string computer) => FirstStarted.TrySetResult();

        public void OnTargetStatus(string computer, TargetStatus status)
        {
        }

        public void OnTargetCompleted(string computer, IReadOnlyList<TargetResult> results, TimeSpan? elapsed)
        {
            Completed[computer] = results;
            Elapsed[computer] = elapsed;
        }
    }
}
