using LazyMix.Data;
using LazyMix.MigrationService;

var builder = Host.CreateApplicationBuilder(args);

builder.AddServiceDefaults();
builder.Services.AddOpenTelemetry()
    .WithTracing(tracing => tracing.AddSource(Worker.ActivitySourceName));

builder.AddNpgsqlDbContext<LazyMixDbContext>(LazyMixDbContext.ConnectionName);
builder.Services.AddHostedService<Worker>();

var host = builder.Build();
host.Run();
