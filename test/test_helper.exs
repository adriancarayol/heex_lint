# Oracle tests need Tailwind installed in test/fixtures/node (npm install).
tailwind? =
  File.regular?(Path.expand("fixtures/node/node_modules/tailwindcss/package.json", __DIR__))

node? = System.find_executable("node") != nil

exclude = if tailwind? and node?, do: [], else: [:tailwind]
ExUnit.start(exclude: exclude)
