# Creating tests

[in Japanese(日本語)](creating_tests_ja.md)

You have an AI assistant create the tests. The result is a Swift file (scenario) under `TestProjects/project1/scenarios/`. You can try each step with the sample app (SUT Store).

## 1. Create a happy-path test

This suits your first test. It creates one test for the normal flow only (add error cases and the like later with "Add to an existing test").

### Prompt for the AI

```text
In project1, create AddToCart.swift as a test.
As a happy-path test, search for "watch" on the search screen, open the product, add it to the cart, and check that the product is in the cart.
Run it on iOS (ios-run) to confirm.
```

The AI assistant compiles it, verifies it without a device (dry-run), runs it on a device, and reports the result.

Expected result:

- `scenarios/AddToCart.swift` is created.
- The test runs, and its history is added to the Test Sessions tab.

## 2. Add a test to an existing test file

### Prompt for the AI

```text
Add a second test to AddToCart.swift in project1.
Search for "scarf" on the search screen, set the quantity to 3 in the product details, add it to the cart,
and check that the quantity of that product in the cart is 3.
Run it on iOS (ios-run) to confirm.
```

Expected result:

- A test scenario is added to the same file.
- The test runs, and its history is added to the Test Sessions tab.

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

To write it yourself, see [Creating a test class](../reference/testclass/creating_testclass.md).

</details>
<br>

If the behavior you ask for is not in the app, the AI assistant reports the actual behavior and leaves the decision of whether that matches the specification to you.

More details:

- [Creating a test class](../reference/testclass/creating_testclass.md)
- [Selector expressions](../reference/selector/selector_expression.md)
- [Writing robust scenarios](../reference/writing/writing_robust_scenarios.md)

<br>

Next: [Running tests](running_tests.md)

### Link
- [index](../index.md)
