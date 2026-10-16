using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Design;

namespace LazyMix.Data;

/// <summary>
/// Used only by <c>dotnet ef</c> tooling (e.g. <c>migrations add</c>), which runs without the
/// Aspire-provided connection string. Never used at runtime.
/// </summary>
public sealed class LazyMixDbContextFactory : IDesignTimeDbContextFactory<LazyMixDbContext>
{
    public LazyMixDbContext CreateDbContext(string[] args)
    {
        var options = new DbContextOptionsBuilder<LazyMixDbContext>()
            .UseNpgsql("Host=localhost;Database=lazymix")
            .Options;

        return new LazyMixDbContext(options);
    }
}
