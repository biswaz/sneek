@testable import SneekLib

func runTemplateEngineTests() {
    print("\nTemplateEngine:")

    test("Basic substitution") {
        let result = try TemplateEngine.render("hello {{name}}", variables: ["name": "world"])
        check(result == "hello world", "expected 'hello world', got '\(result)'")
    }

    test("Multiple variables") {
        let result = try TemplateEngine.render(
            "{{greeting}}, {{name}}!",
            variables: ["greeting": "Hi", "name": "Alice"]
        )
        check(result == "Hi, Alice!", "expected 'Hi, Alice!', got '\(result)'")
    }

    test("Missing variable throws unresolvedPlaceholder") {
        checkThrows(
            { try TemplateEngine.render("{{missing}}", variables: [:]) },
            "should throw for missing variable"
        )
    }

    test("No placeholders returns template unchanged") {
        let template = "just plain text"
        let result = try TemplateEngine.render(template, variables: [:])
        check(result == template, "expected unchanged template")
    }

    test("Adjacent placeholders") {
        let result = try TemplateEngine.render("{{a}}{{b}}", variables: ["a": "X", "b": "Y"])
        check(result == "XY", "expected 'XY', got '\(result)'")
    }

    test("Empty value") {
        let result = try TemplateEngine.render("x{{v}}y", variables: ["v": ""])
        check(result == "xy", "expected 'xy', got '\(result)'")
    }

    test("Single braces left alone") {
        let result = try TemplateEngine.render("{not_a_var}", variables: [:])
        check(result == "{not_a_var}", "expected '{not_a_var}', got '\(result)'")
    }
}
