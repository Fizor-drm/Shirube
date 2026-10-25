// Shirube rule editor vendor bundle.
// Exposes globalThis.ShirubeRuleLib = { cm: {...}, marked, DOMPurify }.
// The dashboard page inlines the built bundle at the head of its single
// <script> and fails closed to a plain textarea when it is absent.
// The markdown language mirrors @codemirror/lang-markdown's mkLang (Language,
// NOT LRLanguage: the markdown parser is not an LR parser, and LRLanguage's
// allowsNesting breaks subword commands with "hasWrappers is not a function"),
// but without lang-markdown's default codeLanguages, whose dynamic imports an
// IIFE bundle must inline (~150KB of JS/CSS/HTML parsers we do not use).
import { EditorView, keymap, lineNumbers, ViewPlugin, Decoration } from "@codemirror/view";
import { EditorState, Compartment } from "@codemirror/state";
import { history, historyKeymap, defaultKeymap, indentWithTab,
         cursorSubwordForward, cursorSubwordBackward,
         deleteGroupForward, deleteGroupBackward } from "@codemirror/commands";
import { HighlightStyle, syntaxHighlighting, Language, defineLanguageFacet,
         syntaxTree, ensureSyntaxTree } from "@codemirror/language";
import { parser, GFM } from "@lezer/markdown";
import { tags } from "@lezer/highlight";
import { marked } from "marked";
import createDOMPurify from "dompurify";

const mdData = defineLanguageFacet({ commentTokens: { block: { open: "<!--", close: "-->" } } });
const markdownLanguage = new Language(mdData, parser.configure(GFM), [], "markdown");

const cm = {
  EditorView, EditorState, Compartment, keymap, lineNumbers, ViewPlugin, Decoration, history,
  historyKeymap, defaultKeymap, indentWithTab, HighlightStyle, syntaxHighlighting,
  cursorSubwordForward, cursorSubwordBackward, deleteGroupForward, deleteGroupBackward,
  Language, syntaxTree, ensureSyntaxTree, markdownLanguage, tags
};

globalThis.ShirubeRuleLib = { cm, marked, DOMPurify: createDOMPurify };
