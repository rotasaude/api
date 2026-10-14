# HTML da página do PEC (ADR 0035): sem asset externo, tudo escapado, estilo
# e script com nonce (a CSP do controller só aceita os deles). Destaca o que
# o PEC não tem: triagens, escutas, agendamentos e campanhas.
module PecExternal
  module Page
    HIGHLIGHT = %w[triage screening appointment campaign].freeze
    NOTICE = "Registros do Rota Saúde — consultas desta cidade estão no PEC.".freeze
    FAILURE = "Não foi possível abrir a linha do tempo do Rota Saúde. Abra de novo pelo PEC; " \
              "se continuar, informe o código abaixo à coordenação.".freeze
    SCRIPT = <<~JS.freeze
      const list = document.getElementById("t");
      const more = document.getElementById("more");
      if (more) more.addEventListener("click", async () => {
        more.disabled = true;
        const r = await fetch("/pec/timeline/more?before=" + encodeURIComponent(more.dataset.before),
          { headers: { "X-Pec-View-Session": list.dataset.session } });
        if (!r.ok) { const p = document.createElement("p"); p.textContent = "Sessão encerrada. Abra de novo pelo PEC."; more.replaceWith(p); return; }
        list.insertAdjacentHTML("beforeend", await r.text());
        const next = r.headers.get("X-Next-Before");
        if (next) { more.dataset.before = next; more.disabled = false; } else { more.remove(); }
      });
    JS

    module_function

    def h(text) = ERB::Util.html_escape(text.to_s)

    # exams: botão "Solicitar exames" (ADR 0036; contrato §8 com A8/D8) — só
    # com exam_pec_bridge utilizável; o token da sessão curta vai num campo
    # oculto do formulário (sem cookie de terceiro, nunca na URL).
    def timeline(display_name:, page:, token:, nonce:, exams: false)
      more = page.next_before ? %(<button id="more" type="button" data-before="#{h(page.next_before)}">Carregar mais</button>) : ""
      layout(<<~HTML, nonce: nonce)
        <p class="notice">#{h(NOTICE)}</p>
        <h1>Linha do tempo — #{h(display_name)}</h1>
        #{exams ? %(<form method="post" action="/pec/exams/form"><input type="hidden" name="token" value="#{h(token)}"><button type="submit">Solicitar exames</button></form>) : ""}
        <ol id="t" data-session="#{h(token)}">#{items(page.entries)}</ol>
        #{more}
        <script nonce="#{h(nonce)}">#{SCRIPT}</script>
      HTML
    end

    def items(entries) = entries.map { |entry| item(entry) }.join

    def item(entry)
      at = entry.occurred_at.in_time_zone.strftime("%d/%m/%Y %H:%M")
      meta = [ entry.unit&.dig(:name), entry.professional&.dig(:name) ].compact.join(" · ")
      summary = entry.summary ? " — #{h(entry.summary)}" : ""
      details = meta.empty? ? "" : "<br><small>#{h(meta)}</small>"
      %(<li class="#{HIGHLIGHT.include?(entry.kind) ? 'hl' : 'e'}"><time>#{h(at)}</time> <strong>#{h(entry.title)}</strong>#{summary}#{details}</li>)
    end

    def failure(code, nonce:) = layout(%(<p>#{h(FAILURE)}</p><p>Código: <code>#{h(code)}</code></p>), nonce: nonce)

    def layout(body, nonce:)
      <<~HTML
        <!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Rota Saúde — linha do tempo</title>
        <style nonce="#{h(nonce)}">body{font-family:system-ui,sans-serif;margin:1rem;color:#111;background:#fff}
        .notice{background:#fff7d6;padding:.5rem;border-left:4px solid #c90}ol{padding-left:1.25rem}li{margin:.4rem 0}
        li.hl strong{color:#0a4d8c}small{color:#555}</style></head>
        <body>#{body}</body></html>
      HTML
    end
  end
end
