# Uma entrada da linha do tempo (ADR 0035; contrato §2), montada por um
# fornecedor (Timeline::Sources::*). `citizen` é a visão do cidadão
# (título, resumo e situação próprios, nunca texto clínico livre).
module Timeline
  Entry = Data.define(:kind, :source_id, :occurred_at, :unit, :professional, :title, :summary, :status, :detail_ref,
                      :citizen, :document) do
    # Ordem total: occurred_at decrescente, kind e id crescentes (a mesma do SQL dos fornecedores).
    def sort_key = [ -occurred_at.to_r, kind, source_id ]
  end
end
