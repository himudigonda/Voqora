(function install(root) {
  "use strict";

  const ELEMENT_NODE = 1;
  const TEXT_NODE = 3;
  const MIN_PARAGRAPH_CHARS = 25;
  const MIN_SEMANTIC_CHARS = 250;
  const MIN_CANDIDATE_CHARS = 140;
  const MAX_SEMANTIC_LINK_DENSITY = 0.5;
  const DEFAULT_MAX_CHARS = 1000000;

  const SKIP_TAGS = new Set([
    "aside", "audio", "button", "canvas", "datalist", "dialog", "embed", "figure", "footer", "head", "iframe",
    "img", "input", "label", "link", "map", "math", "menu", "meta", "nav", "noscript", "object", "option",
    "picture", "script", "select", "style", "svg", "template", "textarea", "video",
  ]);
  const SKIP_ROLES = new Set([
    "alert", "alertdialog", "banner", "complementary", "contentinfo", "dialog", "menu", "menubar",
    "navigation", "search", "toolbar", "tooltip",
  ]);
  const BLOCK_TAGS = new Set([
    "address", "article", "blockquote", "dd", "details", "div", "dl", "dt", "figcaption", "h1", "h2", "h3", "h4",
    "h5", "h6", "header", "hr", "li", "main", "ol", "p", "pre", "section", "summary", "table", "tbody", "tfoot",
    "thead", "tr", "ul",
  ]);
  const PARAGRAPH_TAGS = new Set(["p", "pre", "blockquote", "dd", "li", "td"]);
  const CONTAINER_TAGS = new Set(["article", "div", "main", "section", "td", "body", "blockquote"]);
  const ROOT_TAGS = new Set(["article", "body", "html", "main"]);
  const UNLIKELY = /(^|[\s_-])(ad|ads|advert|advertisement|banner|breadcrumbs?|comment|comments|consent|cookie|disqus|footer|masthead|menu|modal|nav|navbar|newsletter|outbrain|pagination|popup|promo|recommended|related|share|sharing|sidebar|signup|skip|social|sponsor|sponsored|subscribe|taboola|widget)([\s_-]|$)/i;
  const LIKELY = /(^|[\s_-])(article|body|content|entry|main|page|post|story|text|blog)([\s_-]|$)/i;
  const POSITIVE = /(^|[\s_-])(article|body|content|entry|main|post|story|text|blog|prose)([\s_-]|$)/i;
  const NEGATIVE = /(^|[\s_-])(comment|comments|footer|meta|related|share|sidebar|social|sponsor|widget|nav|menu|promo)([\s_-]|$)/i;

  function tagOf(element) {
    return String(element.tagName || element.nodeName || "").toLowerCase();
  }

  function attr(element, name) {
    if (typeof element.getAttribute !== "function") {
      return "";
    }
    const value = element.getAttribute(name);
    return typeof value === "string" ? value : "";
  }

  function classAndId(element) {
    return `${attr(element, "class")} ${attr(element, "id")}`.trim();
  }

  function childList(node) {
    const nodes = node.childNodes;
    return nodes ? Array.from(nodes) : [];
  }

  function normalizeText(text) {
    return String(text ?? "")
      .replace(/\r\n?/g, "\n")
      .replace(/[\t\f\v \u00a0\u2000-\u200a\u202f\u205f\u3000]+/g, " ")
      .replace(/[\u200b-\u200d\u2060\ufeff]/g, "")
      .replace(/ *\n */g, "\n")
      .replace(/\n{3,}/g, "\n\n")
      .trim();
  }

  function countCommas(text) {
    return (String(text).match(/[,\uff0c\u3001]/g) || []).length;
  }

  function scoreFor(length, commas) {
    if (length < MIN_PARAGRAPH_CHARS) {
      return 0;
    }
    return 1 + commas + Math.min(Math.floor(length / 100), 3);
  }

  function paragraphScore(text) {
    const value = normalizeText(text);
    return scoreFor(value.length, countCommas(value));
  }

  function linkDensity(textLength, linkLength) {
    if (textLength <= 0) {
      return 1;
    }
    return Math.min(1, Math.max(0, linkLength / textLength));
  }

  function classWeight(names) {
    const value = String(names ?? "");
    let weight = 0;
    if (POSITIVE.test(value)) {
      weight += 25;
    }
    if (NEGATIVE.test(value)) {
      weight -= 25;
    }
    return weight;
  }

  function isUnlikelyCandidate(names) {
    const value = String(names ?? "");
    return UNLIKELY.test(value) && !LIKELY.test(value);
  }

  function isSemanticMain(element) {
    return tagOf(element) === "main" || attr(element, "role").toLowerCase() === "main";
  }

  function isArticleBody(element) {
    return attr(element, "itemprop").split(/\s+/).includes("articleBody");
  }

  function createContext(options) {
    const predicate = typeof options?.isHidden === "function" ? options.isHidden : () => false;
    const hidden = new Map();
    return {
      isHidden: (element) => {
        if (!hidden.has(element)) {
          hidden.set(element, Boolean(predicate(element)));
        }
        return hidden.get(element);
      },
      maxChars: Number.isInteger(options?.maxChars) && options.maxChars > 0 ? options.maxChars : DEFAULT_MAX_CHARS,
    };
  }

  function isSkipped(element, context, insideContent) {
    const tag = tagOf(element);
    if (SKIP_TAGS.has(tag)) {
      return true;
    }
    if (tag === "header" && !insideContent) {
      return true;
    }
    const role = attr(element, "role").toLowerCase();
    if (SKIP_ROLES.has(role)) {
      return true;
    }
    if (typeof element.hasAttribute === "function" && element.hasAttribute("hidden")) {
      return true;
    }
    if (attr(element, "aria-hidden").toLowerCase() === "true") {
      return true;
    }
    if (!ROOT_TAGS.has(tag) && !isSemanticMain(element) && !isArticleBody(element)
      && isUnlikelyCandidate(classAndId(element))) {
      return true;
    }
    return context.isHidden(element);
  }

  function isContentRoot(element) {
    const tag = tagOf(element);
    return tag === "article" || isSemanticMain(element) || isArticleBody(element);
  }

  function analyze(body, context) {
    const measures = new Map();
    const scores = new Map();
    const semantic = { articleBody: [], article: [], main: [] };

    function visit(element, ancestors, insideContent, insideLink) {
      const tag = tagOf(element);
      const content = insideContent || isContentRoot(element);
      const isLink = insideLink || tag === "a";
      const measure = { text: 0, link: 0, commas: 0 };
      let hasBlockChild = false;
      ancestors.push(element);
      for (const child of childList(element)) {
        if (child.nodeType === TEXT_NODE) {
          const value = String(child.nodeValue ?? "");
          const length = value.replace(/\s+/g, " ").trim().length;
          measure.text += length;
          measure.commas += countCommas(value);
          if (isLink) {
            measure.link += length;
          }
        } else if (child.nodeType === ELEMENT_NODE && !isSkipped(child, context, content)) {
          hasBlockChild = hasBlockChild || BLOCK_TAGS.has(tagOf(child));
          const childMeasure = visit(child, ancestors, content, isLink);
          measure.text += childMeasure.text;
          measure.link += childMeasure.link;
          measure.commas += childMeasure.commas;
        }
      }
      ancestors.pop();
      measures.set(element, measure);
      if (PARAGRAPH_TAGS.has(tag) || (tag === "div" && !hasBlockChild)) {
        creditAncestors(ancestors, scoreFor(measure.text, measure.commas));
      }
      if (isArticleBody(element)) {
        semantic.articleBody.push(element);
      } else if (tag === "article") {
        semantic.article.push(element);
      } else if (isSemanticMain(element)) {
        semantic.main.push(element);
      }
      return measure;
    }

    function creditAncestors(ancestors, score) {
      if (score <= 0) {
        return;
      }
      const divisors = [1, 2, 3];
      let level = 0;
      for (let index = ancestors.length - 1; index >= 0 && level < divisors.length; index -= 1) {
        const ancestor = ancestors[index];
        if (!CONTAINER_TAGS.has(tagOf(ancestor))) {
          continue;
        }
        scores.set(ancestor, (scores.get(ancestor) || 0) + score / divisors[level]);
        level += 1;
      }
    }

    visit(body, [], isContentRoot(body), false);
    return { measures, scores, semantic };
  }

  function pickSemantic(analysis) {
    for (const group of [analysis.semantic.articleBody, analysis.semantic.article, analysis.semantic.main]) {
      let best = null;
      let bestLength = 0;
      for (const element of group) {
        const measure = analysis.measures.get(element);
        if (!measure || measure.text < MIN_SEMANTIC_CHARS) {
          continue;
        }
        if (linkDensity(measure.text, measure.link) > MAX_SEMANTIC_LINK_DENSITY) {
          continue;
        }
        if (measure.text > bestLength) {
          best = element;
          bestLength = measure.text;
        }
      }
      if (best) {
        return best;
      }
    }
    return null;
  }

  function candidateScore(score, textLength, linkLength, names) {
    return score * (1 - linkDensity(textLength, linkLength)) + classWeight(names);
  }

  function pickScored(analysis) {
    let best = null;
    let bestScore = 0;
    for (const [element, score] of analysis.scores) {
      const measure = analysis.measures.get(element);
      if (!measure || measure.text < MIN_CANDIDATE_CHARS) {
        continue;
      }
      const total = candidateScore(score, measure.text, measure.link, classAndId(element));
      if (total > bestScore) {
        best = element;
        bestScore = total;
      }
    }
    return best;
  }

  function collectText(rootElement, context) {
    const parts = [];
    let length = 0;

    function push(text) {
      if (length < context.maxChars) {
        parts.push(text);
        length += text.length;
      }
    }

    function walk(element, content) {
      for (const child of childList(element)) {
        if (length >= context.maxChars) {
          return;
        }
        if (child.nodeType === TEXT_NODE) {
          push(String(child.nodeValue ?? "").replace(/\s+/g, " "));
          continue;
        }
        if (child.nodeType !== ELEMENT_NODE || isSkipped(child, context, content)) {
          continue;
        }
        const tag = tagOf(child);
        if (tag === "br") {
          push("\n");
          continue;
        }
        const block = BLOCK_TAGS.has(tag);
        if (block) {
          push("\n\n");
        } else if (tag === "td" || tag === "th") {
          push(" ");
        }
        walk(child, content || isContentRoot(child));
        if (block) {
          push("\n\n");
        }
      }
    }

    walk(rootElement, isContentRoot(rootElement));
    return normalizeText(parts.join("")).slice(0, context.maxChars).trim();
  }

  function extractReadableText(doc, options) {
    const body = doc?.body;
    if (!body) {
      return "";
    }
    const context = createContext(options);
    const analysis = analyze(body, context);
    const chosen = pickSemantic(analysis) || pickScored(analysis) || body;
    const text = collectText(chosen, context);
    if (chosen !== body && text.length < MIN_CANDIDATE_CHARS) {
      return collectText(body, context);
    }
    return text;
  }

  function selectedText(win) {
    const doc = win?.document;
    const active = doc?.activeElement;
    const tag = active ? tagOf(active) : "";
    if (tag === "input" && String(active.type ?? "").toLowerCase() === "password") {
      return "";
    }
    if ((tag === "textarea" || tag === "input") && typeof active.value === "string") {
      const start = active.selectionStart;
      const end = active.selectionEnd;
      if (Number.isInteger(start) && Number.isInteger(end) && end > start) {
        return normalizeText(active.value.slice(start, end));
      }
    }
    const selection = typeof win?.getSelection === "function" ? win.getSelection() : null;
    return normalizeText(selection ? selection.toString() : "");
  }

  function browserIsHidden(win) {
    return (element) => {
      try {
        return win.getComputedStyle(element).display === "none";
      } catch {
        return false;
      }
    };
  }

  root.VoqoraPageText = Object.freeze({
    browserIsHidden,
    candidateScore,
    classWeight,
    extractReadableText,
    isUnlikelyCandidate,
    linkDensity,
    normalizeText,
    paragraphScore,
    selectedText,
  });
})(globalThis);
