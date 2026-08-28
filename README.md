# Vault

Vault is a native Omarchy plugin for browsing, searching, reading, and editing
Markdown files from a local vault. It provides a compact bar widget and a full
panel with keyboard navigation, Markdown rendering, and direct editing.

## Requirements

- Omarchy with Quickshell plugin support
- `find`, `rg`, `head`, and a writable Markdown vault

The default vault path is `~/amphora`. Set an absolute `vaultPath` in the
plugin settings to use another directory.

## Installation

```bash
omarchy plugin add https://github.com/harbefas/omarchy-vault.git --enable
```

The plugin can also be installed from a local checkout:

```bash
omarchy plugin add /path/to/omarchy-vault --enable
```

After installation, place the widget in the bar through Omarchy's plugin
settings. The full panel can be opened from the widget or with the configured
panel shortcut.

## Usage

- Click a note or press `Enter` to open it.
- Use `j`/`k` or the arrow keys to move through notes.
- Press `/` to search.
- Press `Enter` to open the selected note in the full panel.
- Press `e` to edit the current note and `Esc` to return to reading.
- Press `q` or `Esc` to leave the current surface.

Markdown content is rendered in the reader. Edits are written directly to the
selected file only after the explicit save action.

## Removal

```bash
omarchy plugin remove nfvelten.vault
```

Removing the plugin does not delete or modify any Markdown files in the vault.

## License

MIT. See [LICENSE](LICENSE).
