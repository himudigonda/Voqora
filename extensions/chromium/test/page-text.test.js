import assert from "node:assert/strict";
import { test } from "node:test";

import { documentWith, el, loadPageText } from "./helpers/fakes.js";

const pageText = loadPageText();

const longParagraph = (label) =>
  `${label} is a long paragraph with enough words, commas, and detail to look like real article content for a reader.`;

function siteChrome() {
  return [
    el("header", {}, el("a", { href: "/" }, "Site name"), " Home About Contact"),
    el("nav", {}, el("ul", {}, el("li", {}, el("a", {}, "News")), el("li", {}, el("a", {}, "Sport")))),
  ];
}

test("prefers the article element and strips navigation, asides, footers and scripts", () => {
  const doc = documentWith(
    ...siteChrome(),
    el(
      "main",
      {},
      el(
        "article",
        {},
        el("header", {}, el("h1", {}, "Headline")),
        el("p", {}, longParagraph("First")),
        el("script", {}, "trackReader()"),
        el("aside", {}, "Related stories you may like"),
        el("p", {}, longParagraph("Second")),
        el("footer", {}, "Share this article"),
      ),
    ),
    el("footer", {}, "Copyright"),
  );
  const result = pageText.extractReadableText(doc);
  assert.equal(result, `Headline\n\n${longParagraph("First")}\n\n${longParagraph("Second")}`);
});

test("uses role=main and articleBody when there is no article", () => {
  const doc = documentWith(
    ...siteChrome(),
    el(
      "div",
      { role: "main" },
      el(
        "div",
        { itemprop: "articleBody" },
        el("p", {}, longParagraph("Body")),
        el("p", {}, longParagraph("More")),
        el("p", {}, longParagraph("Last")),
      ),
      el("div", {}, el("p", {}, "Text outside the article body that should not be read")),
    ),
  );
  assert.equal(
    pageText.extractReadableText(doc),
    `${longParagraph("Body")}\n\n${longParagraph("More")}\n\n${longParagraph("Last")}`,
  );
});

test("scores the largest text-dense block when there are no semantic hints", () => {
  const links = el(
    "div",
    { class: "link-farm" },
    ...Array.from({ length: 12 }, (_, index) => el("p", {}, el("a", {}, `A very long link title number ${index}, with commas, here`))),
  );
  const story = el(
    "div",
    { class: "story-body" },
    el("p", {}, longParagraph("One")),
    el("p", {}, longParagraph("Two")),
    el("p", {}, longParagraph("Three")),
  );
  const doc = documentWith(...siteChrome(), links, story);
  assert.equal(
    pageText.extractReadableText(doc),
    `${longParagraph("One")}\n\n${longParagraph("Two")}\n\n${longParagraph("Three")}`,
  );
});

test("skips unlikely class names but keeps likely content wrappers", () => {
  const doc = documentWith(
    el(
      "div",
      { class: "content has-sidebar" },
      el("p", {}, longParagraph("Kept")),
      el("div", { class: "sidebar" }, el("p", {}, longParagraph("Sidebar"))),
      el("div", { id: "comments" }, el("p", {}, longParagraph("Comment"))),
      el("div", { class: "cookie-banner" }, "We use cookies"),
      el("p", {}, longParagraph("Also kept")),
    ),
  );
  assert.equal(pageText.extractReadableText(doc), `${longParagraph("Kept")}\n\n${longParagraph("Also kept")}`);
});

test("skips hidden content through attributes and the injected predicate", () => {
  const hiddenByStyle = el("p", { "data-hidden": "yes" }, longParagraph("Styled hidden"));
  const doc = documentWith(
    el(
      "article",
      {},
      el("p", {}, longParagraph("Visible")),
      el("p", { hidden: "" }, longParagraph("Hidden attribute")),
      el("p", { "aria-hidden": "true" }, longParagraph("Aria hidden")),
      hiddenByStyle,
      el("p", {}, longParagraph("Visible again")),
    ),
  );
  const result = pageText.extractReadableText(doc, { isHidden: (element) => element === hiddenByStyle });
  assert.equal(result, `${longParagraph("Visible")}\n\n${longParagraph("Visible again")}`);
});

test("falls back to the body for short pages and keeps line breaks", () => {
  const doc = documentWith(el("div", {}, "Line one", el("br"), "Line   two"), el("nav", {}, "Menu"));
  assert.equal(pageText.extractReadableText(doc), "Line one\nLine two");
});

test("ignores an article that is mostly links", () => {
  const linkArticle = el(
    "article",
    {},
    ...Array.from({ length: 10 }, (_, index) => el("p", {}, el("a", {}, `Teaser headline ${index} that is fairly long`))),
  );
  const story = el("div", { class: "post" }, el("p", {}, longParagraph("Real")), el("p", {}, longParagraph("Story")));
  const result = pageText.extractReadableText(documentWith(linkArticle, story));
  assert.equal(result, `${longParagraph("Real")}\n\n${longParagraph("Story")}`);
});

test("respects maxChars and returns empty text without a body", () => {
  const doc = documentWith(el("article", {}, el("p", {}, longParagraph("A")), el("p", {}, longParagraph("B"))));
  const result = pageText.extractReadableText(doc, { maxChars: 30 });
  assert.ok(result.length <= 30);
  assert.ok(result.startsWith("A is a long"));
  assert.equal(pageText.extractReadableText({}), "");
});

test("tables read cells with spaces and rows on new lines", () => {
  const table = el(
    "table",
    {},
    el("tbody", {}, el("tr", {}, el("td", {}, "Name"), el("td", {}, "Value")), el("tr", {}, el("td", {}, "A"), el("td", {}, "1"))),
  );
  assert.equal(pageText.extractReadableText(documentWith(table)), "Name Value\n\nA 1");
});

test("normalizeText collapses whitespace and removes zero-width characters", () => {
  assert.equal(pageText.normalizeText("  a\u00a0\u00a0b\u200b c \r\n\r\n\r\n\n d  "), "a b c\n\nd");
});

test("paragraphScore, linkDensity and classWeight follow the heuristic", () => {
  assert.equal(pageText.paragraphScore("too short"), 0);
  assert.equal(pageText.paragraphScore("a, b, c and enough words to pass the minimum"), 3);
  assert.equal(pageText.paragraphScore("x".repeat(450)), 4);
  assert.equal(pageText.linkDensity(0, 0), 1);
  assert.equal(pageText.linkDensity(100, 25), 0.25);
  assert.equal(pageText.classWeight("article-body"), 25);
  assert.equal(pageText.classWeight("comment-list"), -25);
  assert.equal(pageText.classWeight("post comments"), 0);
  assert.equal(pageText.candidateScore(10, 100, 50, ""), 5);
  assert.equal(pageText.isUnlikelyCandidate("share-buttons"), true);
  assert.equal(pageText.isUnlikelyCandidate("main-content share"), false);
  assert.equal(pageText.isUnlikelyCandidate("header-shadow"), false);
});

test("selectedText reads text field selections and the page selection", () => {
  const field = { tagName: "TEXTAREA", value: "Hello brave new world", selectionStart: 6, selectionEnd: 15 };
  assert.equal(pageText.selectedText({ document: { activeElement: field }, getSelection: () => null }), "brave new");
  const win = {
    document: { activeElement: { tagName: "BODY" } },
    getSelection: () => ({ toString: () => "  Selected\n\n\n text  " }),
  };
  assert.equal(pageText.selectedText(win), "Selected\n\ntext");
  assert.equal(pageText.selectedText({ document: {}, getSelection: () => null }), "");
});
