# Oracle tests need Tailwind: `npm install` in test/fixtures/node for the
# Node path, and Tailwind's standalone binary at test/fixtures/bin/tailwindcss
# for the CLI path.
node? = System.find_executable("node") != nil

tailwind? =
  File.regular?(Path.expand("fixtures/node/node_modules/tailwindcss/package.json", __DIR__))

standalone? = File.regular?(Path.expand("fixtures/bin/tailwindcss", __DIR__))

exclude =
  if(tailwind? and node?, do: [], else: [:tailwind]) ++
    if(standalone?, do: [], else: [:standalone])

ExUnit.start(exclude: exclude)
