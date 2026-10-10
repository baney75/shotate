import { api } from "./api";

/** "Made by Donovan Baney · dbaney.com · GitHub · X @baney75", with working links. */
export function credits(): string {
  const links: [string, string][] = [["dbaney.com", "https://dbaney.com"], ["GitHub", "https://github.com/baney75/snapmark"],
                                     ["X @baney75", "https://x.com/baney75"]];
  return `<p class="credits">Made by Donovan Baney · ${links.map(([t, u]) => `<a href="${u}" data-url="${u}">${t}</a>`).join(" · ")}</p>`;
}

export function wireLinks(root: HTMLElement) {
  root.querySelectorAll<HTMLAnchorElement>("a[data-url]").forEach((a) =>
    a.addEventListener("click", (e) => { e.preventDefault(); void api.openUrl(a.dataset.url!); }));
}
