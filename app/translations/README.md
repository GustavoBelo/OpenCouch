# Translations

Translations use Qt Linguist with stable ids:

- `opencouch_en.ts` is the English catalog and `opencouch_pt_BR.ts` is the Portuguese catalog.
- UI messages use `qsTrId("domain.key")` in QML and `qtTrId("domain.key")` in C++.
- Translated text lives only in the catalog; do not use phrases as keys in the code.
- The app automatically picks the catalog matching the system locale.
- CMake generates the `.qm` files and bundles them into the Flatpak app.

To add a language:

1. Copy `opencouch_en.ts` to `opencouch_<locale>.ts`.
2. Translate only the `<translation>` elements.
3. Add the new file to the `TS_FILES` list in `app/CMakeLists.txt`.
4. Rebuild the Flatpak.
