const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { runInNewContext } = require("node:vm");
const { transformSync } = require("esbuild");

// Execute the real activation path without VS Code or a server process. Only
// capture options and features passed to LanguageClient; never inherit the harness environment.
async function activateClient() {
  const clients = [];
  class LanguageClient {
    constructor(id, name, serverOptions, clientOptions) {
      Object.assign(this, { id, name, serverOptions, clientOptions });
      this.features = [];
      clients.push(this);
    }
    registerFeature(feature) {
      this.features.push(feature);
    }
    async start() {
      this.featuresAtStart = [...this.features];
      this.started = true;
    }
  }
  const vscode = {
    workspace: {
      workspaceFolders: [{ uri: { fsPath: "/workspace" }, name: "workspace" }],
    },
    window: {
      createOutputChannel: () => ({
        info() {},
        error(message) {
          throw new Error(message);
        },
      }),
    },
  };
  const filename = join(__dirname, "../src/extension.ts");
  const { code } = transformSync(readFileSync(filename, "utf8"), {
    loader: "ts",
    format: "cjs",
    target: "es2020",
    sourcefile: filename,
  });
  const module = { exports: {} };
  runInNewContext(
    code,
    {
      module,
      exports: module.exports,
      process: { env: {} },
      require(name) {
        if (name === "vscode") return vscode;
        if (name === "vscode-languageclient/node") return { LanguageClient };
        throw new Error(`Unexpected extension import: ${name}`);
      },
    },
    { filename },
  );
  const context = { subscriptions: [] };
  await module.exports.activate(context);
  return { clients, subscriptions: context.subscriptions };
}

module.exports = { activateClient };
