# app/services/clinical_documents/page.rb
# HTML da página pública (ADR 0033): sem assets externos, tudo escapado. O
# formulário posta JSON em /v/lookup com um script mínimo e mostra o resultado.
module ClinicalDocuments
  module Page
    KINDS = { "sick_note" => "Atestado", "attendance_declaration" => "Declaração de comparecimento",
              "prescription" => "Receita", "exam_requisition" => "Requisição de exames",
              "lab_report" => "Laudo laboratorial" }.freeze
    CATEGORIES = { "special_control" => "Receita de controle especial", "antimicrobial" => "Receita de antimicrobiano" }.freeze
    STATUS = { "valid" => "Válido", "cancelled" => "Cancelado", "awaiting_signature" => "Aguardando assinatura digital",
               "rectified" => "Retificado — substituído por um laudo novo" }.freeze
    MODES = { "advanced" => "Assinatura eletrônica avançada (Lei 14.063/2020)", "paper" => "Papel (assinatura à mão)" }.freeze

    module_function

    def h(text) = ERB::Util.html_escape(text.to_s)

    def result(data)
      issued = Time.iso8601(data[:issued_at]).in_time_zone.strftime("%d/%m/%Y %H:%M")
      professional = [ data.dig(:professional, :name), data.dig(:professional, :council) ].compact.join(" — ")
      rows = [ [ "Documento", CATEGORIES[data[:category]] || KINDS.fetch(data[:kind]) ], [ "Emitido em", issued ],
               ([ "Profissional", professional ] unless professional.empty?),
               [ "Unidade", data[:unit] ],
               [ "Paciente", "#{data.dig(:patient, :initials)} (nascido(a) em #{data.dig(:patient, :birth_year) || '—'})" ],
               [ "Situação", STATUS.fetch(data[:status]) + (data[:cancelled_at] ? " em #{Time.iso8601(data[:cancelled_at]).in_time_zone.strftime('%d/%m/%Y %H:%M')}" : "") ],
               [ "Modo", data[:mode] == "digital" ? "Assinado digitalmente#{' (simulada — sem validade jurídica)' if data[:simulated]}" : MODES.fetch(data[:mode], MODES["paper"]) ],
               ([ "SHA-256 do PDF", data[:pdf_sha256] ] if data[:pdf_sha256]) ].compact
      if data[:sncr]
        rows << [ "Numeração SNCR", "#{data.dig(:sncr, :number)}#{' (simulada — sem validade)' if data.dig(:sncr, :simulated)}" ]
        if data[:status] == "cancelled"
          rows << [ "Atenção", "Receita cancelada: não dispense. O SNCR não registra o cancelamento; vale esta conferência." ]
        end
      end
      table = rows.map { |label, value| "<tr><th>#{h(label)}</th><td>#{h(value)}</td></tr>" }.join
      link = data[:signed_pdf_url] ? %(<p><a href="#{h(data[:signed_pdf_url])}">Baixar o PDF assinado</a></p>) : ""
      layout("<table>#{table}</table>#{link}")
    end

    def form
      layout(<<~HTML)
        <form id="f"><label>Código <input name="short_code" autocomplete="off" required></label>
        <label>Ano de nascimento do paciente <input name="birth_year" inputmode="numeric" maxlength="4" required></label>
        <button>Conferir</button></form><div id="r" role="status"></div>
        <script>
        document.getElementById("f").addEventListener("submit", async (e) => {
          e.preventDefault();
          const d = new FormData(e.target);
          const r = await fetch("/v/lookup", { method: "POST", headers: { "Content-Type": "application/json", "Accept": "application/json" },
            body: JSON.stringify({ short_code: d.get("short_code"), birth_year: d.get("birth_year") }) });
          const out = document.getElementById("r");
          if (r.status === 429) { out.textContent = "Muitas tentativas. Tente de novo em alguns minutos."; return; }
          if (!r.ok) { out.textContent = "Documento não encontrado. Confira o código e o ano."; return; }
          const j = await r.json();
          const status = { valid: "Válido", cancelled: "Cancelado", rectified: "Retificado", awaiting_signature: "Aguardando assinatura digital" }[j.status] || j.status;
          out.textContent = [ status, j.professional.name, j.unit ].filter(Boolean).join(" — ");
        });
        </script>
      HTML
    end

    def layout(body)
      <<~HTML
        <!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Conferência de documento</title>
        <style>body{font-family:system-ui,sans-serif;max-width:40rem;margin:2rem auto;padding:0 1rem;color:#111;background:#fff}
        th{text-align:left;padding:.25rem 1rem .25rem 0;vertical-align:top}label{display:block;margin:.5rem 0}</style></head>
        <body><h1>Conferência de documento — Rota Saúde</h1>#{body}</body></html>
      HTML
    end
  end
end
