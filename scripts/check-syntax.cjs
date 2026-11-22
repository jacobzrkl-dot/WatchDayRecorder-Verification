// Syntax only: does not type-check Apple frameworks or execute XCTest.
// node --liftoff-only --single-threaded scripts/check-syntax.cjs <web-tree-sitter.cjs> <swift-grammar.wasm>
const fs = require('node:fs');
const path = require('node:path');

async function main() {
    const [runtimePath, grammarPath] = process.argv.slice(2);
    if (!runtimePath || !grammarPath) {
        throw new Error('Provide web-tree-sitter.cjs and Swift grammar WASM paths.');
    }
    const { Parser, Language } = require(path.resolve(runtimePath));
    await Parser.init({
        locateFile: () => path.join(path.dirname(path.resolve(runtimePath)), 'web-tree-sitter.wasm')
    });
    const parser = new Parser();
    parser.setLanguage(await Language.load(path.resolve(grammarPath)));
    const root = path.resolve(__dirname, '..');
    const files = [];
    function walk(directory) {
        for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
            const file = path.join(directory, entry.name);
            if (entry.isDirectory()) walk(file);
            else if (entry.name.endsWith('.swift')) files.push(file);
        }
    }
    walk(path.join(root, 'Sources'));
    walk(path.join(root, 'Tests'));
    let failures = 0;
    for (const file of files) {
        const tree = parser.parse(fs.readFileSync(file, 'utf8'));
        if (tree.rootNode.hasError) {
            failures++;
            console.error(`FAIL: ${path.relative(root, file)}`);
            function inspect(node) {
                if (node.type === 'ERROR' || node.isMissing) {
                    console.error(`  ${node.type} at ${node.startPosition.row + 1}:${node.startPosition.column + 1}`);
                }
                for (const child of node.children) inspect(child);
            }
            inspect(tree.rootNode);
        }
        tree.delete();
    }
    parser.delete();
    console.log(`Parsed ${files.length} Swift files; syntax failures: ${failures}`);
    process.exitCode = failures ? 1 : 0;
}

main().catch(error => {
    console.error(error.message);
    process.exitCode = 1;
});
