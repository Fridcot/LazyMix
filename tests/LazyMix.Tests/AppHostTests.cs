using System.Net;
using Aspire.Hosting.Testing;

namespace LazyMix.Tests;

public class AppHostTests
{
    private static readonly TimeSpan _timeout = TimeSpan.FromMinutes(3);

    [Test]
    public async Task Api_is_healthy_after_migrations_complete()
    {
        using var cts = new CancellationTokenSource(_timeout);

        var appHost = await DistributedApplicationTestingBuilder.CreateAsync<Projects.LazyMix_AppHost>(
            ["LazyMix:EphemeralDatabase=true"], cts.Token);
        await using var app = await appHost.BuildAsync(cts.Token);
        await app.StartAsync(cts.Token);

        await app.ResourceNotifications.WaitForResourceHealthyAsync("api", cts.Token);

        using var client = app.CreateHttpClient("api");
        using var response = await client.GetAsync("/health", cts.Token);

        await Assert.That(response.StatusCode).IsEqualTo(HttpStatusCode.OK);
    }
}
