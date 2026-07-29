export type ThemeMode = "system" | "light" | "dark";

export function applyTheme(theme: string) {
  const root = document.documentElement;
  const prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
  const isDark = theme === "dark" || (theme === "system" && prefersDark);
  if (isDark) {
    root.classList.add("dark");
  } else {
    root.classList.remove("dark");
  }
}

export function getInitialTheme(): ThemeMode {
  if (typeof window === "undefined") {
    return "system";
  }
  return (localStorage.getItem("hark-theme") as ThemeMode) || "system";
}
