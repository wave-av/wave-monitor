// eslint.config.js — flat config (ESLint 9)
const js = require('@eslint/js');
const tseslint = require('typescript-eslint');
const reactHooks = require('eslint-plugin-react-hooks');
const globals = require('globals');

module.exports = tseslint.config(
  { ignores: ['out/**', 'release/**', 'dist/**', 'node_modules/**', '*.config.js', '*.config.ts'] },
  // Gate scripts run under plain node (no test runner, no Electron).
  { files: ['scripts/**/*.mjs'], languageOptions: { globals: globals.node } },
  // R2 absence probes: Buildkite step scripts + colocated tests, plain node.
  { files: ['.buildkite/**/*.mjs'], languageOptions: { globals: globals.node } },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  reactHooks.configs['recommended-latest'],
  {
    files: ['**/*.{ts,tsx}'],
    languageOptions: { parserOptions: { projectService: false } },
  },
);
