# Entrada de uma ficha na fila LEDI da cidade (ADR 0028; spec §6.3/§6.4). Só
# entra com o interruptor ledi_export LIGADO e record_mode diferente de off —
# credencial recusada ou PEC fora do ar não impedem a entrada (a ficha espera).
# A mesma fonte (source_type, source_id, ficha_type) entra uma vez. Precisa
# rodar na conexão da cidade.
module Ledi
  module Enqueue
    module_function

    def call(ficha, city:)
      Ledi::Ficha.assert!(ficha)
      return nil unless Platform::Features.enabled?(city, :ledi_export) && city.record_mode != "off"

      source = ficha.source
      existing = find_existing(source, ficha)
      return existing if existing

      uuid = "#{ficha.cnes}-#{SecureRandom.uuid}"
      entry = begin
        ApplicationRecord.transaction(requires_new: true) do
          LediOutboxEntry.create!(uuid: uuid, ficha_type: ficha.type, competence: ficha.competence,
                                  source_type: source[:type], source_id: source[:id],
                                  ledi_version: Ledi::Version::ACTIVE, next_attempt_at: Time.current,
                                  bytes: Ledi::Transport.wrap(ficha, city: city, uuid: uuid))
        end
      rescue ActiveRecord::RecordNotUnique
        return find_existing(source, ficha) || raise
      end
      Ledi::DeliverJob.perform_later
      entry
    end

    def find_existing(source, ficha)
      LediOutboxEntry.find_by(source_type: source[:type], source_id: source[:id], ficha_type: ficha.type)
    end
  end
end
