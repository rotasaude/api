# Formas do contrato §2: <entry> do profissional e <citizen_entry> do cidadão
# (`document` sempre presente, null fora dos documentos — pedido W4 do wpda).
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
      { id: "#{entry.kind}:#{entry.source_id}", kind: entry.kind, occurred_at: entry.occurred_at.iso8601,
        unit: entry.unit && { name: entry.unit[:name] }, professional_name: view[:professional_name],
        title: view[:title], summary: view[:summary], status: view[:status], document: entry.document }
    end
  end
end
