# Linhas da fila LEDI cujas fontes são de um cidadão (api#43; spec §6). Hoje a
# única fonte real é a escuta (Screening → atendimento → cidadão). A exclusão
# confirmada apaga conteúdo e códigos; pendente e em envio viram failed para
# não irem ao PEC sem conteúdo. Aceita é imutável e já não tem conteúdo.
module Ledi
  module CitizenSources
    module_function

    def entries_for(citizen_ids)
      screenings = Screening.joins(:attendance).where(attendances: { citizen_id: citizen_ids }).select(:id)
      LediOutboxEntry.where(source_type: "Screening", source_id: screenings)
    end

    def scrub!(citizen_ids)
      entries_for(citizen_ids).where.not(status: "accepted").update_all(
        "payload = NULL, last_error_codes = '[]'::jsonb, " \
        "status = CASE WHEN status IN ('pending', 'sending') THEN 'failed' ELSE status END, updated_at = now()"
      )
    end
  end
end
