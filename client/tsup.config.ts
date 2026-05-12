import { defineConfig } from "tsup";

export default defineConfig({
	entry: ["src/index.ts"],
	format: ["esm", "cjs"],
	dts: true,
	sourcemap: true,
	clean: true,
	target: "es2020",
	platform: "browser",
	treeshake: true,
	minify: false,
	splitting: false,
	outExtension({ format }) {
		return { js: format === "esm" ? ".mjs" : ".cjs" };
	},
});
