const Module = require("node:module");

const registrations = new Map();
function register(name, selector, provider) {
  registrations.set(name, { selector, provider });
  return { dispose() { registrations.delete(name); } };
}

// Only the editor API is substituted. Feature classification, ordering, and
// provider registration run through vscode-languageclient itself.
const vscode = {
  CancellationError: class extends Error {},
  CompletionItem: class {},
  CodeLens: class {},
  CodeAction: class {},
  DocumentLink: class {},
  InlayHint: class {},
  CallHierarchyItem: class {},
  TypeHierarchyItem: class {},
  SymbolInformation: class {},
  Diagnostic: class {},
  languages: {
    registerDocumentRangeFormattingEditProvider: (...args) => register("rangeFormatting", ...args),
    registerHoverProvider: (...args) => register("hover", ...args),
    registerReferenceProvider: (...args) => register("references", ...args),
    registerRenameProvider: (...args) => register("rename", ...args),
  },
};

const originalLoad = Module._load;
let BaseLanguageClient, DocumentRangeFormattingFeature, HoverFeature, ReferencesFeature, RenameFeature;
try {
  Module._load = function (name, ...args) {
    if (name === "vscode") return vscode;
    return originalLoad.call(this, name, ...args);
  };
  ({ BaseLanguageClient } = require("vscode-languageclient/lib/common/client.js"));
  ({ DocumentRangeFormattingFeature } = require("vscode-languageclient/lib/common/formatting.js"));
  ({ HoverFeature } = require("vscode-languageclient/lib/common/hover.js"));
  ({ ReferencesFeature } = require("vscode-languageclient/lib/common/reference.js"));
  ({ RenameFeature } = require("vscode-languageclient/lib/common/rename.js"));
} finally {
  Module._load = originalLoad;
}

function initializeProviders(capabilities, { featuresAtStart = [], clientOptions } = {}) {
  const client = {
    _features: [],
    _dynamicFeatures: new Map(),
    _capabilities: structuredClone(capabilities),
    _clientOptions: clientOptions ?? { documentSelector: [{ language: "ruby", scheme: "file" }] },
    protocol2CodeConverter: { asDocumentSelector(value) { return value; } },
  };
  const features = [DocumentRangeFormattingFeature, HoverFeature, ReferencesFeature, RenameFeature]
    .map((Feature) => new Feature(client));
  try {
    for (const feature of [...features, ...featuresAtStart]) {
      BaseLanguageClient.prototype.registerFeature.call(client, feature);
    }
    BaseLanguageClient.prototype.initializeFeatures.call(client, undefined);
    return { capabilities: client._capabilities, registrations: new Map(registrations) };
  } finally {
    for (const feature of features) feature.clear();
  }
}

module.exports = { initializeProviders };
