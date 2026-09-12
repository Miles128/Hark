export type ThemeMode = "system" | "light" | "dark";

let mediaListener: ((e: MediaQueryListEvent) => void) | null = null;
let mediaQuery: MediaQueryList | null = null;
let currentMode: ThemeMode = "system";

function resolveDark(theme: ThemeMode): boolean {
  if (theme === "dark") return true;
  if (theme === "light") return false;
  return window.matchMedia("(prefers-color-scheme: dark)").matches;
}

function setDarkClass(isDark: boolean) {
  const root = document.documentElement;
  root.classList.toggle("dark", isDark);
  root.style.colorScheme = isDark ? "dark" : "light";
}

function onSystemChange() {
  if (currentMode === "system") {
    setDarkClass(resolveDark("system"));
  }
}

/** 应用主题。system 时跟随 OS，并监听系统切换。 */
export function applyTheme(theme: string) {
  const mode = (theme === "light" || theme === "dark" || theme === "system"
    ? theme
    : "system") as ThemeMode;
  currentMode = mode;
  setDarkClass(resolveDark(mode));

  if (typeof window === "undefined") return;

  if (!mediaQuery) {
    mediaQuery = window.matchMedia("(prefers-color-scheme: dark)");
  }
  if (!mediaListener) {
    mediaListener = () => onSystemChange();
    mediaQuery.addEventListener("change", mediaListener);
  }
}

export function getInitialTheme(): ThemeMode {
  if (typeof window === "undefined") {
    return "system";
  }
  return (localStorage.getItem("hark-theme") as ThemeMode) || "system";
}
