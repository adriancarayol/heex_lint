// Generates classes no stylesheet declares, and throws on one of them.
module.exports = function ({ addComponents, matchUtilities }) {
  addComponents({ ".plug-card": { "max-width": "65ch" } })
  matchUtilities(
    {
      boom: (value) => {
        if (value === "bad") throw new Error("boom")
        return { color: value }
      },
    },
    { values: { bad: "bad", red: "red" } }
  )
}
