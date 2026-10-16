using Microsoft.EntityFrameworkCore;

namespace LazyMix.Data;

public sealed class LazyMixDbContext(DbContextOptions<LazyMixDbContext> options) : DbContext(options)
{
    /// <summary>Connection name shared by the AppHost resource and client registrations.</summary>
    public const string ConnectionName = "lazymix";

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        base.OnModelCreating(modelBuilder);
        modelBuilder.ApplyConfigurationsFromAssembly(typeof(LazyMixDbContext).Assembly);
    }
}
