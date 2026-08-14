# Traduções

As traduções usam o Qt Linguist com IDs estáveis:

- `opencouch_en.ts` é o catálogo em inglês e `opencouch_pt_BR.ts` é o catálogo em português.
- As mensagens da interface usam `qsTrId("dominio.chave")` no QML e `qtTrId("dominio.chave")` no C++.
- O texto traduzido fica somente no catálogo; não use frases como chaves no código.
- O aplicativo escolhe automaticamente o catálogo compatível com o locale do sistema.
- O CMake gera os arquivos `.qm` e os incorpora ao aplicativo Flatpak.

Para adicionar um idioma:

1. Copie `opencouch_en.ts` para `opencouch_<locale>.ts`.
2. Traduza apenas os elementos `<translation>`.
3. Adicione o novo arquivo à lista `TS_FILES` em `app/CMakeLists.txt`.
4. Recompile o Flatpak.
