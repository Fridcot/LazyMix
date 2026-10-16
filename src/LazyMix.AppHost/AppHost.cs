using Microsoft.Extensions.Configuration;

var builder = DistributedApplication.CreateBuilder(args);

// Integration tests set this to get a throwaway database instead of the persistent dev one.
var ephemeralDatabase = builder.Configuration.GetValue<bool>("LazyMix:EphemeralDatabase");

var postgres = builder.AddPostgres("postgres");
if (!ephemeralDatabase)
{
    postgres
        .WithDataVolume()
        .WithPgAdmin()
        .WithLifetime(ContainerLifetime.Persistent);
}

// Must match LazyMixDbContext.ConnectionName.
var database = postgres.AddDatabase("lazymix");

var migrations = builder.AddProject<Projects.LazyMix_MigrationService>("migrations")
    .WithReference(database)
    .WaitFor(database);

var api = builder.AddProject<Projects.LazyMix_Api>("api")
    .WithReference(database)
    .WaitForCompletion(migrations)
    .WithHttpHealthCheck("/health")
    .WithExternalHttpEndpoints();

var web = builder.AddViteApp("web", "../web")
    .WithReference(api)
    .WaitFor(api);

api.PublishWithContainerFiles(web, "wwwroot");

builder.Build().Run();
