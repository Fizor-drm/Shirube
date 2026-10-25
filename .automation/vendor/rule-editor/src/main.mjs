// Shirube rule editor vendor bundle.
// Exposes globalThis.ShirubeRuleLib = { cm: {...}, marked, DOMPurify }.
// The dashboard page inlines the built bundle at the head of its single
// <script> and fails closed to a plain textarea when it is absent.
// The markdown language is assembled from @lezer/markdown directly instead of
// @codemirror/lang-markdown: lang-markdown's default codeLanguages pull in the
// JS/CSS/HTML parsers via dynamic imports, which an IIFE bundle must inline
// (~150KB extra) and the rule editor does not need embedded-code highlighting.
import { EditorView, keymap, lineNumbers, ViewPlugin, Decoration } from "@codemirror/view";
import { EditorState, Compartment } from "@codemirror/state";
import { history, historyKeymap, defaultKeymap, indentWithTab } from "@codemirror/commands";
import { HighlightStyle, syntaxHighlighting, LRLanguage } from "@codemirror/language";
import { parser, GFM } from "@lezer/markdown";
import { tags } from "@lezer/highlight";
import { marked } from "marked";
import createDOMPurify from "dompurify";

const markdownLanguage = LRLanguage.define({ parser: parser.configure(GFM) });

const cm = {
  EditorView, EditorState, Compartment, keymap, lineNumbers, ViewPlugin, Decoration, history,
  historyKeymap, defaultKeymap, indentWithTab, HighlightStyle, syntaxHighlighting,
  markdownLanguage, tags
};

globalThis.ShirubeRuleLib = { cm, marked, DOMPurify: createDOMPurify };
