# Translations

Translations use Qt Linguist with stable ids:

- `opencouch_en.ts` is the source (base) catalog; the remaining catalogs hold the actual translations.
- Current catalogs: `opencouch_pt_BR.ts` (Portuguese, Brazil), `opencouch_en_GB.ts` (English, GB), `opencouch_de_DE.ts` (German), `opencouch_es_ES.ts` (Spanish), `opencouch_fr_FR.ts` (French), `opencouch_zh_CN.ts` (Chinese, Simplified).
- UI messages use `qsTrId("domain.key")` in QML and `qtTrId("domain.key")` in C++.
- Translated text lives only in the catalog; do not use phrases as keys in the code.
- The app automatically picks the catalog matching the system locale and falls back to the English catalog for messages that are not translated yet.
- CMake generates the `.qm` files from the `TS_FILES` list in `app/CMakeLists.txt` and bundles them into the application package.

To add a language:

1. Copy `opencouch_en.ts` to `opencouch_<locale>.ts`.
2. Translate only the `<translation>` elements.
3. Add the new file to the `TS_FILES` list in `app/CMakeLists.txt`.
4. Rebuild the application package.
