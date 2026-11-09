# Formas do contrato §2: <entry> do profissional e <citizen_entry> do cidadão
# (`document` sempre presente, null fora dos documentos — pedido W4 do wpda;
# `status_label` opcional, hoje só do exame — A24 do módulo 21a;
# `return_guidance` opcional, só da urgência com retorno à UBS — W1 do 32a).
module Timeline
  module Json
    module_function

    def professional(entry)
      { id: "#{entry.kind}:#{entry.source_id}", kind: entry.kind, occurred_at: entry.occurred_at.iso8601,
        unit: entry.unit, professional: entry.professional, title: entry.title, summary: entry.summary,
        status: entry.status, detail_ref: entry.detail_ref }
    end

    def citizen(entry)
      view = entry.citizen
      unit = view.key?(:unit) ? view[:unit] : entry.unit # vacina: a visão do cidadão decide (nula na transcrição)
      { id: "#{entry.kind}:#{entry.source_id}", kind: entry.kind, occurred_at: entry.occurred_at.iso8601,
        unit: unit && { name: unit[:name] }, professional_name: view[:professional_name],
        title: view[:title], summary: view[:summary], status: view[:status], document: entry.document }
        .tap do |body|
          body[:status_label] = view[:status_label] if view[:status_label] # A24: só quando presente
          body[:return_guidance] = view[:return_guidance] if view[:return_guidance] # 32a W1: só quando presente
        end
    end
  end
end
