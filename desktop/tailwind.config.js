/** @type {import('tailwindcss').Config} */
export default {
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        canvas: "#f4f7f6",
        ink: "#14201c",
        muted: "#60736c",
        line: "#dbe5e1",
        brand: "#18745a",
        danger: "#b84431",
        warning: "#9a6b10",
      },
      boxShadow: {
        panel: "0 1px 2px rgba(20, 32, 28, 0.06)",
      },
    },
  },
  plugins: [],
};
