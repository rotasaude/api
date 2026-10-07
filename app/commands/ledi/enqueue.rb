# Entrada de uma ficha na fila LEDI da cidade (ADR 0028; spec §6.3/§6.4). Só
# entra com o interruptor ledi_export LIGADO e record_mode diferente de off —
# credencial recusada ou PEC fora do ar não impedem a entrada (a ficha espera).
# A mesma fonte (source_type, source_id, ficha_type) entra uma vez, salvo
# quando substitui uma recusada (replaces:). Precisa
# rodar na conexão da cidade.
module Ledi
  module Enqueue
    module_function

    # replaces: a recusada que esta ficha substitui (regeneração a partir da
    # origem, ADR 0030 §5). Sem ela, a mesma fonte entra uma vez.
    def call(ficha, city:, replaces: nil)
      Ledi::Ficha.assert!(ficha)
      return nil unless accepting?(city)

      source = ficha.source
      unless replaces
        existing = find_existing(source, ficha)
        return existing if existing
      end

      uuid = "#{ficha.cnes}-#{SecureRandom.uuid}"
      entry = begin
        ApplicationRecord.transaction(requires_new: true) do
          LediOutboxEntry.create!(uuid: uuid, ficha_type: ficha.type, competence: ficha.competence,
                                  source_type: source[:type], source_id: source[:id],
                                  ledi_version: Ledi::Version::ACTIVE, next_attempt_at: Time.current,
                                  replaces_outbox_id: replaces&.id,
                                  bytes: Ledi::Transport.wrap(ficha, city: city, uuid: uuid))
        end
      rescue ActiveRecord::RecordNotUnique
        return find_existing(source, ficha) || raise
      end
      Ledi::DeliverJob.perform_later
      entry
    end

    # record_mode relido da plataforma: Current.city vem do CityCatalog, com
    # cache de ~30 s, e uma cidade recém-desligada não pode receber ficha (R35).
    def accepting?(city)
      Platform::Features.enabled?(city, :ledi_export) &&
        Platform::Features.settings(city)[:record_mode] != "off"
    end

    # A mais recente da fonte (com recusadas regeneradas há mais de uma).
    def find_existing(source, ficha)
      LediOutboxEntry.where(source_type: source[:type], source_id: source[:id], ficha_type: ficha.type)
                     .order(created_at: :desc, id: :desc).first
    end
  end
end
