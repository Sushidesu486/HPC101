const detailsToken = "MPE_PYMDOWN_DETAILS";

function renderPymdownDetails(markdown) {
  const lines = markdown.split(/\r?\n/);
  const output = [];
  const stack = [];
  let fence = null;

  function indentOf(line) {
    const match = line.match(/^ */);
    return match ? match[0].length : 0;
  }

  function escapeHtml(text) {
    return text
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function stripDetailsIndent(line) {
    let stripped = line;
    for (let i = 0; i < stack.length; i++) {
      stripped = stripped.replace(/^ {4}/, "");
    }
    return stripped;
  }

  function openDetails(kind, title, state) {
    const opened = state === "+" ? " open" : "";
    output.push(`<!--${detailsToken}:open:${kind}:${opened}:${escapeHtml(title)}-->`);
    output.push("");
  }

  function closeDetailsTo(indent) {
    while (stack.length && stack[stack.length - 1] >= indent) {
      stack.pop();
      output.push("");
      output.push(`<!--${detailsToken}:close-->`);
    }
  }

  function updateFence(line) {
    const match = line.match(/^(\s*)(`{3,}|~{3,})/);
    if (!match) {
      return;
    }

    const marker = match[2];
    if (!fence) {
      fence = marker;
    } else if (marker[0] === fence[0] && marker.length >= fence.length) {
      fence = null;
    }
  }

  for (const line of lines) {
    const marker = line.match(/^(\s*)\?\?\?([+-]?)(?:\s+(\S+))?(?:\s+"([^"]*)")?\s*$/);
    const indent = indentOf(line);

    if (line.trim() === "") {
      output.push(line);
      continue;
    }

    if (!fence && marker) {
      closeDetailsTo(indent);
      const state = marker[2];
      const kind = marker[3] || "note";
      const title = marker[4] || kind;

      openDetails(kind, title, state);
      stack.push(indent);
      continue;
    }

    closeDetailsTo(indent);
    const transformed = stripDetailsIndent(line);
    output.push(transformed);
    updateFence(transformed);
  }

  closeDetailsTo(0);
  return output.join("\n");
}

function replaceDetailsTokens(html) {
  return html
    .replace(/<p>\s*<!--MPE_PYMDOWN_DETAILS:open:([^:]+):([^:]*):([\s\S]*?)-->\s*<\/p>/g, function(_, kind, opened, title) {
      return `<details class="admonition ${kind}"${opened}><summary>${title}</summary>`;
    })
    .replace(/<p>\s*<!--MPE_PYMDOWN_DETAILS:close-->\s*<\/p>/g, "</details>")
    .replace(/<!--MPE_PYMDOWN_DETAILS:open:([^:]+):([^:]*):([\s\S]*?)-->/g, function(_, kind, opened, title) {
      return `<details class="admonition ${kind}"${opened}><summary>${title}</summary>`;
    })
    .replace(/<!--MPE_PYMDOWN_DETAILS:close-->/g, "</details>");
}

({
  onWillParseMarkdown: async function(markdown) {
    return renderPymdownDetails(markdown);
  },

  onDidParseMarkdown: async function(html) {
    return replaceDetailsTokens(html);
  },
})
