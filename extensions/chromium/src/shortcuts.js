const MAC_MODIFIERS = new Map([
  ["⌃", "Control"],
  ["⌥", "Alt"],
  ["⇧", "Shift"],
  ["⌘", "Meta"],
]);

export function ariaKeyShortcut(shortcut) {
  const text = String(shortcut ?? "").trim();
  if (text.length === 0) {
    return "";
  }
  if (text.includes("+")) {
    return text.replace(/\bCtrl\b/g, "Control").replace(/\bCommand\b/g, "Meta");
  }
  const keys = [];
  let rest = "";
  for (const character of text) {
    if (MAC_MODIFIERS.has(character)) {
      keys.push(MAC_MODIFIERS.get(character));
    } else {
      rest += character;
    }
  }
  if (rest.length > 0) {
    keys.push(rest);
  }
  return keys.join("+");
}
