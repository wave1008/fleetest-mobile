---
paths:
  - "docs/*.md"
  - "docs/design/*.md"
  - "docs/maintainer-notes/*.md"
  - "docs/remote-runner/*.md"
  - "docs/performance-tuning/*.md"
  - "docs/verification/*.md"
---

# 保守者向けドキュメントの規律

- **書き方の規約は docs/README.md「書き方」**(冒頭の表・大きさ・節の ID・正典と記録・台帳の項目)。文書を足す/直す前に読む
- 文書を足す・消す・改名したら **docs/README.md の索引も直す**(`docsIndex.test.mjs` が食い違いを落とす)
- 節を参照するときは ID(`MN-0`)で書く。文書名の無い `§N` を新たに書かない
- 利用者向けの docs/user-docs/ はこの規約の対象外(en/ja の対の規約は CLAUDE.md「ドキュメント」)
