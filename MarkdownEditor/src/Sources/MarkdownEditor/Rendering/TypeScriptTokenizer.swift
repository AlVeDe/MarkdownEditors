/// TypeScript = the JavaScript lexer plus TypeScript's type-level keywords.
struct TypeScriptTokenizer: LanguageTokenizer {
    private let javascript = JavaScriptTokenizer(extraKeywords: [
        "abstract", "any", "as", "asserts", "boolean", "declare", "enum",
        "implements", "infer", "interface", "is", "keyof", "namespace",
        "never", "number", "object", "override", "private", "protected",
        "public", "readonly", "satisfies", "string", "symbol", "type",
        "unknown", "unique"
    ])

    func tokenize(_ code: String) -> [Token] {
        javascript.tokenize(code)
    }
}
