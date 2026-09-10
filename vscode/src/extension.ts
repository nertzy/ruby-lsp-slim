import * as vscode from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  type StaticFeature,
} from "vscode-languageclient/node";

let client: LanguageClient | undefined;

const slimCapabilities: StaticFeature = {
  getState: () => ({ kind: "static" }),
  fillClientCapabilities() {},
  preInitialize(capabilities) {
    // Ruby LSP advertises range formatting independently of enabledFeatures.
    // Filter it before this dedicated client's providers are registered.
    delete capabilities.documentRangeFormattingProvider;
  },
  initialize() {},
  clear() {},
};

export async function activate(context: vscode.ExtensionContext) {
  const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
  if (!workspaceFolder) {
    return;
  }

  const outputChannel = vscode.window.createOutputChannel("Ruby LSP Slim", {
    log: true,
  });

  outputChannel.info("Starting Ruby LSP Slim...");

  // Let ruby-lsp handle its own bundling (SetupBundler) by NOT using
  // `bundle exec`. This ensures it uses .ruby-lsp/Gemfile which includes
  // all addon gems.
  const env = { ...process.env };
  delete env.BUNDLE_GEMFILE;

  const serverOptions: ServerOptions = {
    command: "ruby-lsp",
    args: [],
    options: {
      cwd: workspaceFolder.uri.fsPath,
      env: env,
    },
  };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [
      { language: "slim", scheme: "file" },
      { language: "slim", scheme: "untitled" },
    ],
    workspaceFolder: workspaceFolder,
    outputChannel: outputChannel,
    connectionOptions: {
      maxRestartCount: 5,
    },
    initializationOptions: {
      // Arrays default unlisted features to off; object keys default to on.
      enabledFeatures: [
        "hover",
        "definition",
        "completion",
        "documentSymbols",
        "semanticHighlighting",
        "diagnostics",
        "workspaceSymbol",
        "documentHighlights",
      ],
    },
  };

  client = new LanguageClient(
    "rubyLspSlim",
    "Ruby LSP Slim",
    serverOptions,
    clientOptions,
  );

  client.registerFeature(slimCapabilities);

  try {
    await client.start();
    outputChannel.info("Ruby LSP Slim started successfully");
  } catch (error) {
    outputChannel.error(`Failed to start Ruby LSP Slim: ${error}`);
  }

  context.subscriptions.push(client);
}

export async function deactivate() {
  if (client) {
    await client.stop();
  }
}
