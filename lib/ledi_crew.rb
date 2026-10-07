# Semente de dev da Produção e-SUS (módulo 16; spec §10). Grava direto na fila
# uma competência corrente com todos os estados, para o painel do dashboard e
# do console terem o que mostrar. Nada é enviado: as linhas nascem com
# next_attempt_at no futuro distante. A semente não altera record_mode nem liga
# interruptor algum; nada é enviado enquanto ledi_export estiver desligado ou
# record_mode=off.
# Identificadores fictícios; payload só nas linhas não aceitas, com a ficha
# sintética de verdade. Idempotente: não semeia se a fila já tem linha
# sintética da competência.
module LediCrew
  CNES = "9999991"
  INE = "9999999991"
  PROFESSIONAL_CNS = "700000000000005"
  CBO = "225142"
  REJECTIONS = [ [ { "field" => "cnes", "code" => "not_allowed" } ],
                 [ { "field" => "cboCodigo_2002", "code" => "not_allowed" } ] ].freeze
  PLAN = { "accepted" => 6, "rejected" => 3, "pending" => 2, "failed" => 1 }.freeze

  module_function

  def seed_current_city(slug:)
    competence = Ledi::Deadline.current(Time.zone.today)
    return { created: 0 } if LediOutboxEntry.for_competence(competence).where(source_type: "synthetic").exists?

    city = City.find_by(slug: slug)
    created = 0
    PLAN.each do |status, count|
      count.times do |index|
        create_entry(city, status, index)
        created += 1
      end
    end
    { created: created }
  end

  def create_entry(city, status, index)
    ficha = Ledi::Fichas::Synthetic.new(cnes: CNES, ine: INE, professional_cns: PROFESSIONAL_CNS, cbo: CBO,
                                        attended_at: Time.zone.today.beginning_of_month.in_time_zone + 9.hours)
    uuid = "#{CNES}-#{SecureRandom.uuid}"
    attrs = { uuid: uuid, ficha_type: ficha.type, competence: ficha.competence, source_type: "synthetic",
              source_id: ficha.source_id, ledi_version: Ledi::Version::ACTIVE, status: status,
              next_attempt_at: 10.years.from_now, attempts: status == "pending" ? 0 : 1 }
    if status == "accepted"
      attrs.merge!(accepted_at: Time.current, first_attempt_at: Time.current)
    else
      attrs[:bytes] = Ledi::Transport.wrap(ficha, city: city || Struct.new(:id).new(SecureRandom.uuid), uuid: uuid)
      attrs[:last_error_codes] = REJECTIONS[index % REJECTIONS.size] if status == "rejected"
      attrs[:last_error_codes] = Ledi::ErrorCodes.transport("http_error") if status == "failed"
      attrs[:first_attempt_at] = 2.days.ago if status == "failed"
    end
    LediOutboxEntry.create!(attrs)
  end
end
