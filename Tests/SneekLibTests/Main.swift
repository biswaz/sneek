@main
struct TestMain {
    static func main() {
        print("Running Sneek tests...\n")
        runModelsTests()
        runConfigStoreTests()
        runSecretResolverTests()
        runTemplateEngineTests()
        runTunnelManagerTests()
        runSessionManagerTests()
        runMCPServerTests()
        runScriptGeneratorTests()
        runIntegrationTests()
        print("")
        report()
    }
}
