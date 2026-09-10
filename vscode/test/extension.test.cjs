const assert = require("node:assert/strict");
const { test } = require("node:test");
const { spawnSync } = require("node:child_process");
const { join } = require("node:path");
const { activateClient } = require("./activate-client.cjs");
const { initializeProviders } = require("./initialize-providers.cjs");

async function initializeServer(initializationOptions) {
  const {
    clients: [client],
  } = await activateClient();
  const result = spawnSync("ruby", [join(__dirname, "initialize_server.rb")], {
    input: JSON.stringify({
      capabilities: { general: { positionEncodings: ["utf-16"] } },
      initializationOptions:
        initializationOptions ?? client.clientOptions.initializationOptions,
    }),
    encoding: "utf8",
    timeout: 10000,
  });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr);
  return { client, ...JSON.parse(result.stdout) };
}

test("activation starts only the dedicated Slim client", async () => {
  const { clients, subscriptions } = await activateClient();
  assert.equal(clients.length, 1);
  const [client] = clients;
  assert.equal(client.id, "rubyLspSlim");
  assert.equal(client.started, true);
  assert.deepEqual(subscriptions, [client]);
  assert.deepEqual(
    JSON.parse(JSON.stringify(client.clientOptions.documentSelector)),
    [
      { language: "slim", scheme: "file" },
      { language: "slim", scheme: "untitled" },
    ],
  );
});

test("initialization uses an allowlist so new Ruby LSP features stay disabled", async () => {
  const {
    clients: [client],
  } = await activateClient();
  const { enabledFeatures } = client.clientOptions.initializationOptions;
  assert.ok(Array.isArray(enabledFeatures));
  assert.ok(enabledFeatures.length > 0);
  assert.ok(enabledFeatures.every((feature) => typeof feature === "string"));
  assert.equal(new Set(enabledFeatures).size, enabledFeatures.length);
});

test("native initialization keeps supported providers and omits unadapted features", async (t) => {
  const { capabilities, version } = await initializeServer();
  t.diagnostic(`Ruby LSP ${version}`);
  for (const provider of [
    "hoverProvider",
    "definitionProvider",
    "completionProvider",
    "documentSymbolProvider",
    "semanticTokensProvider",
    "diagnosticProvider",
    "workspaceSymbolProvider",
    "documentHighlightProvider",
    "referencesProvider",
    "renameProvider",
  ]) {
    assert.ok(capabilities[provider], provider);
  }
  assert.equal(capabilities.renameProvider.prepareProvider, true);
  assert.deepEqual(capabilities.textDocumentSync, {
    openClose: true,
    change: 2,
  });
  assert.equal(capabilities.positionEncoding, "utf-16");
  for (const provider of [
    "foldingRangeProvider",
    "selectionRangeProvider",
    "documentLinkProvider",
    "signatureHelpProvider",
    "typeHierarchyProvider",
    "codeLensProvider",
    "documentFormattingProvider",
    "codeActionProvider",
    "inlayHintProvider",
    "documentOnTypeFormattingProvider",
  ]) {
    assert.ok(!capabilities[provider], provider);
  }
});

test("dedicated client removes range formatting before real provider registration", async (t) => {
  const { client, capabilities, version } = await initializeServer();
  assert.equal(capabilities.documentRangeFormattingProvider, true);
  const result = initializeProviders(capabilities, client);
  t.diagnostic(
    `Ruby LSP ${version}: dedicated range-format providers=${Number(result.registrations.has("rangeFormatting"))}`,
  );
  assert.equal(result.registrations.has("rangeFormatting"), false);
  assert.deepEqual(
    [...result.registrations.keys()],
    ["hover", "references", "rename"],
  );
  for (const { selector } of result.registrations.values()) {
    assert.deepEqual(
      JSON.parse(JSON.stringify(selector)),
      JSON.parse(JSON.stringify(client.clientOptions.documentSelector)),
    );
  }
  assert.equal(
    typeof result.registrations.get("rename").provider.prepareRename,
    "function",
  );
  const { documentRangeFormattingProvider, ...supportedCapabilities } =
    capabilities;
  assert.deepEqual(result.capabilities, supportedCapabilities);

  // A fresh initialize response after a restart must be filtered as well.
  assert.deepEqual(
    initializeProviders(capabilities, client).capabilities,
    supportedCapabilities,
  );
});

test("ordinary clients retain range formatting and the remaining providers", async (t) => {
  const { capabilities, version } = await initializeServer({});
  assert.equal(capabilities.foldingRangeProvider, true);
  assert.equal(capabilities.selectionRangeProvider, true);
  assert.ok(capabilities.signatureHelpProvider);
  assert.ok(capabilities.typeHierarchyProvider);
  const result = initializeProviders(capabilities);
  t.diagnostic(
    `Ruby LSP ${version}: shared-client range-format providers=${Number(result.registrations.has("rangeFormatting"))}`,
  );
  assert.deepEqual(
    [...result.registrations.keys()],
    ["rangeFormatting", "hover", "references", "rename"],
  );
  assert.deepEqual(result.capabilities, capabilities);
  for (const { selector } of result.registrations.values()) {
    assert.deepEqual(selector, [{ language: "ruby", scheme: "file" }]);
  }
});
